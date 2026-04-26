"
Chat management functions.
"

(require hyrule.argmove [-> ->>])
(require hyjinx.macros [prepend append])

(import hyjinx [first])

(import chasm-engine [log])

(import tiktoken)
(import openai)

(import tenacity [retry retry-if-exception-type stop-after-attempt wait-random-exponential])

(import chasm_engine.lib *)


(defclass ChatError [RuntimeError])

(setv APIErrors (tuple [openai.APIConnectionError
                 openai.InternalServerError
                 openai.APIStatusError
                 openai.APITimeoutError]))

;; Message functions
;; -----------------------------------------------------------------------------

(defn msg [role content]
  "Just a simple dict with the needed fields."
  (if content
      {"role" role
       "content" (.strip content)}
      (raise (ChatError f"No content in message (role: {role})."))))

(defn system [content]
  (msg "system" content))

(defn user [content]
  (msg "user" content))

(defn assistant [content]
  (msg "assistant" content))

;; Chat functions
;; -----------------------------------------------------------------------------

(defn token-length [x]
  "The number of tokens, roughly, of a chat history (or anything with a meaningful __repr__).
  We use tiktoken because I don't want to install pytorch."
  (let [encoding (tiktoken.get-encoding "cl100k_base")]
    (->> x
         (str)
         (encoding.encode)
         (len))))

(defn standard-roles [messages * [roles ["assistant" "user" "system"]]]
  "Remove messages not with standard role."
  (lfor m messages
        :if (in (:role m) roles)
        m))
  
(defn truncate [messages [spare-length None]]
  "Hack away non-system messages until below length.
  This will fail if the system message is too long.
  Non-destructive."
  (let [l (- (config "context_length") (or spare-length (config "max_tokens") 300))
        ms (.copy messages)
        roles (set (map (fn [x] (:role x)) ms))
        too-long (> (token-length (str messages)) l)]
    (cond
      (and too-long (= (len roles) 1))
      (raise (ChatError f"System messages too long ({(token-length (str ms))} tkns) - nothing left to cut."))

      too-long
      (do (for [m ms]
            ;; remove the first non-system message
            (when (!= (:role m) "system")
              (.remove ms m)
              (break)))
          (truncate ms :spare-length spare-length))

      ;; first non-system message must be a user message
      (and (= "system" (:role (first messages)))
           (= "assistant" (:role (second messages))))
      (+ (first messages) (cut messages 2 None))

      :else
      messages)))

(defn msg->dlg [user-name assistant-name message]
  "Replace standard roles with given names and ignore roles with system messages.
  Return modified dialogue message or None." 
  (let [role (:role message)]
    (cond (= role "user") (msg user-name (:content message))
          (= role "assistant") (msg assistant-name (:content message))
          :else None)))

(defn msgs->dlg [user-name assistant-name messages]
  "Replace standard roles with given names and filter out system messages.
  Return dialogue." 
  (->> messages
       (map (partial msg->dlg user-name assistant-name))
       (sieve)
       (list)))

(defn dlg->msg [user-name assistant-name message]
  "Replace given names with standard roles and replace other roles with system messages.
  Return modified message."
  (let [role (:role message)]
    (cond (= role user-name) (user (:content message))
          (= role assistant-name) (assistant (:content message))
          :else (system f"{role}: {(:content message)}"))))
    
(defn dlg->msgs [user-name assistant-name messages]
  "Replace given names with standard roles and replace other roles with system messages.
  Return modified messages."
  (->> messages
       (map (partial dlg->msg user-name assistant-name))
       (list)))

(defn flip-roles [messages]
  (dlg->msgs "assistant" "user" messages))

;; Remote API calls
;; -----------------------------------------------------------------------------

;; TODO hyjinx llm async
;; TODO streaming -- but how to stream to client?

(defn :async _openai [params messages [stream False]]
  "Openai-compatible API calls: https://platform.openai.com/docs/api-reference"
  (let [api-key (.pop params "api_key" None)
        base-url (.pop params "api_base" None)
        client (openai.AsyncOpenAI :api-key api-key
                                   :base-url base-url)]
    (if stream
        ;; Return async generator for streaming
        (client.chat.completions.create
          :messages (standard-roles messages)
          :stream True
          #** params)
        ;; Non-streaming: return full content
        (let [response (await
                         (client.chat.completions.create
                           :messages (standard-roles messages)
                           #** params))]
          (. (. (first response.choices) message) content)))))

(defn :async 
  [(retry :wait (wait-random-exponential :min 0.5 :max 10)
          :stop (stop-after-attempt 6)
          :retry (retry-if-exception-type APIErrors))]
  respond [messages [provider "backend"] #** kwargs]
  "Reply to a list of messages and return just content.
  The messages should already have the standard roles.
  Uses `providers.default` unless the `provider` arg is specified.
  
  Note: 'openai' scheme means OpenAI-compatible API (vLLM, Ollama, etc.)."
  (let [conf (or (config "providers" provider) {})
        defaults {"api_key" "sk-dummy"
                  "max_tokens" (config "max_tokens")
                  "api_scheme" "openai"
                  "model" None}
        params (| defaults conf (or kwargs {}))
        api-scheme (.pop params "api_scheme")]
    (try
      (await (_openai params messages))
      (except [err [Exception]]
        (log.error f"Chat API exception ({api-scheme})" :exception err)
        (raise (ChatError (.join " " [api-scheme (str err)])))))))

(defn :async chat [messages #** kwargs] ; -> message
  "An assistant response (message) to a list of messages.
  The messages should already have the standard roles."
  (-> (respond messages #** kwargs)
      (await)
      (assistant)))

(defn :async respond-stream [messages [provider "backend"] #** kwargs]
  "Stream response to a list of messages.
  Yields chunks of content as they arrive."
  (let [conf (or (config "providers" provider) {})
        defaults {"api_key" "sk-dummy"
                  "max_tokens" (config "max_tokens")
                  "api_scheme" "openai"
                  "model" None}
        params (| defaults conf (or kwargs {}))
        api-scheme (.pop params "api_scheme")]
    (try
      (match api-scheme
             "openai" (_openai params messages :stream True)
             _        (_openai params messages :stream True))
      (except [err [Exception]]
        (log.error f"Chat API streaming exception ({api-scheme})" :exception err)
        (raise (ChatError (.join " " [api-scheme (str err)])))))))

(defn :async collect-stream [stream]
  "Collect streaming response into full content."
  (let [content []]
    (async-for [chunk stream]
      (when (and chunk (first chunk.choices))
        (let [delta (. (first chunk.choices) delta)]
          (when delta.content
            (.append content delta.content)))))
    (.join "" content)))
