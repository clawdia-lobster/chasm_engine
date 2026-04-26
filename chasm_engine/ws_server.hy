"
WebSocket server for Chasm.
Implements the Chasm WebSocket Protocol v1.0.
"

(require hyrule [defmain unless])
(require hyrule.argmove [-> ->>])
(import hyrule [assoc])

(import asyncio)
(import json)
(import time [time])
(import datetime [datetime])
(import uuid [uuid4])
(import hashlib [sha256])
(import hmac [compare-digest])

(import jwt)
(import websockets.exceptions)

(import chasm_engine [log])
(import chasm_engine [engine])
(import chasm_engine.lib [config config-file])
(import chasm_engine.state [get-account set-account update-account get-character])


;; * Configuration
;; -----------------------------------------------------------------------------

(setv _config-loaded False)
(setv JWT-SECRET None)
(setv JWT-ALGORITHM "HS256")
(setv SESSION-EXPIRY-SECONDS 3600)
(setv MAX-INPUT-LENGTH 1000)
(setv RATE-LIMIT-WINDOW 10)
(setv RATE-LIMIT-MAX 5)

(defn ensure-config []
  "Load config if not already loaded."
  (global _config-loaded JWT-SECRET)
  (unless _config-loaded
    (setv JWT-SECRET (or (config "jwt_secret") "change-me-in-production"))
    (setv _config-loaded True)))


;; * Session Management
;; -----------------------------------------------------------------------------

(setv _sessions {})

(defn generate-token [player-name]
  "Generate a JWT session token."
  (let [now (time)
        payload {"player" player-name
                 "iat" now
                 "exp" (+ now SESSION-EXPIRY-SECONDS)}]
    (jwt.encode payload JWT-SECRET :algorithm JWT-ALGORITHM)))


(defn verify-token [token]
  "Verify a JWT token. Returns player name or None."
  (try
    (let [payload (jwt.decode token JWT-SECRET :algorithms [JWT-ALGORITHM])]
      (.get payload "player"))
    (except [jwt.ExpiredSignatureError]
      None)
    (except [jwt.InvalidTokenError]
      None)))


(defn create-session [player-name websocket]
  "Create a new session."
  (let [token (generate-token player-name)
        session {"player" player-name
                 "websocket" websocket
                 "created_at" (time)
                 "last_active" (time)}]
    (assoc _sessions token session)
    token))


(defn get-session [token]
  "Get session by token."
  (.get _sessions token None))


(defn touch-session [token]
  "Update last_active timestamp."
  (let [session (.get _sessions token None)]
    (when session
      (assoc session "last_active" (time)))))


(defn delete-session [token]
  "Remove a session."
  (.pop _sessions token None))


;; * Rate Limiting
;; -----------------------------------------------------------------------------

(setv _rate-limits {})

(defn check-rate-limit [token]
  "Check if request is within rate limits. Returns True if allowed."
  (let [now (time)
        window-start (- now RATE-LIMIT-WINDOW)
        timestamps (.get _rate-limits token [])
        recent (lfor ts timestamps :if (> ts window-start) ts)]
    (assoc _rate-limits token recent)
    (< (len recent) RATE-LIMIT-MAX)))


;; * JSON-RPC Helpers
;; -----------------------------------------------------------------------------

(defn make-response [result req-id]
  "Create a success response."
  {"jsonrpc" "2.0"
   "result" result
   "id" req-id})


(defn make-error [code message [data None] [req-id None]]
  "Create an error response."
  (let [error {"code" code "message" message}]
    (when data
      (assoc error "data" data))
    {"jsonrpc" "2.0"
     "error" error
     "id" req-id}))


(defn make-notification [method params]
  "Create a server notification."
  {"jsonrpc" "2.0"
   "method" method
   "params" params})


;; * Error Codes
;; -----------------------------------------------------------------------------

(setv ERR-PARSE -32700
      ERR-INVALID-REQUEST -32600
      ERR-METHOD-NOT-FOUND -32601
      ERR-INVALID-PARAMS -32602
      ERR-INTERNAL -32603
      ERR-PLAYER-TAKEN -32001
      ERR-INVALID-PASSPHRASE -32002
      ERR-WORLD-FULL -32003
      ERR-SESSION-EXPIRED -32010
      ERR-SESSION-NOT-FOUND -32011
      ERR-INPUT-TOO-LONG -32012
      ERR-RATE-LIMIT -32030)


;; * Method Handlers
;; -----------------------------------------------------------------------------

(defn :async handle-spawn [params websocket]
  "Handle spawn method."
  (let [player-name (.get params "player" None)
        passphrase (.get params "passphrase" None)
        character-card (.get params "character_card" {})]
    (if (not player-name)
      (make-error ERR-INVALID-PARAMS "Missing 'player' parameter")
      (let [existing (get-account player-name)]
        (cond
          ;; Name taken with passphrase
          (and existing (.get existing "passphrase"))
            (if (and passphrase (compare-digest 
                                  (.get existing "passphrase")
                                  (.hexdigest (sha256 (.encode passphrase)))))
              ;; Authenticated - resume session
              (let [token (create-session player-name websocket)
                    spawn-result (await (engine.spawn-player player-name #** character-card))]
                (cond
                  (is spawn-result None)
                    (make-error ERR-INTERNAL "Spawn returned no result")
                  (= (.get spawn-result "role") "error")
                    (make-error ERR-INTERNAL (:content spawn-result "Spawn failed"))
                  :else
                    (make-response {
                      "player" player-name
                      "session_token" token
                      "expires_at" (+ (time) SESSION-EXPIRY-SECONDS)
                      "world" (:world spawn-result)
                      "location" (:place (:player spawn-result))
                      "message" (:result spawn-result)
                    } None)))
              (make-error ERR-INVALID-PASSPHRASE "Invalid passphrase"))
          
          ;; Name taken without passphrase
          existing
            (make-error ERR-PLAYER-TAKEN "Player name already taken")
          
          ;; New player
          True
            (do
              ;; Store passphrase if provided
              (when passphrase
                (update-account player-name 
                               :passphrase (.hexdigest (sha256 (.encode passphrase)))))
              (let [token (create-session player-name websocket)
                    spawn-result (await (engine.spawn-player player-name #** character-card))]
                (cond
                  (is spawn-result None)
                    (make-error ERR-INTERNAL "Spawn returned no result")
                  (= (.get spawn-result "role") "error")
                    (make-error ERR-INTERNAL (:content spawn-result "Spawn failed"))
                  :else
                    (make-response {
                      "player" player-name
                      "session_token" token
                      "expires_at" (+ (time) SESSION-EXPIRY-SECONDS)
                      "world" (:world spawn-result)
                      "location" (:place (:player spawn-result))
                      "message" (:result spawn-result)
                    } None)))))))))


(defn :async handle-parse [params auth websocket]
  "Handle parse method. Supports streaming via stream=true parameter."
  (let [token (.get auth "session_token" None)
        input (.get params "input" "")
        stream (.get params "stream" False)]
    (cond
      (not token)
        (make-error ERR-SESSION-NOT-FOUND "Missing session token")
      
      (not (verify-token token))
        (make-error ERR-SESSION-EXPIRED "Session expired")
      
      (> (len input) MAX-INPUT-LENGTH)
        (make-error ERR-INPUT-TOO-LONG f"Input too long (max {MAX-INPUT-LENGTH} chars)")
      
      (not (check-rate-limit token))
        (make-error ERR-RATE-LIMIT "Rate limit exceeded")
      
      True
        (let [player-name (verify-token token)]
          (touch-session token)
          (if stream
            ; Streaming path
            (let [send-notification (fn :async [method data]
                                     (await (.send websocket
                                                   (json.dumps (make-notification method data)))))]
              (await (engine.parse-stream player-name input websocket send-notification)))
            ; Non-streaming path
            (let [result (await (engine.parse player-name input))
                  player-data (:player result)]
              (make-response {
                "message" (:result result)
                "player" {
                  "name" player-name
                  "location" (:place player-data)
                  "coords" (:coords result)
                  "inventory" (:inventory player-data [])
                  "score" (:score player-data 0)
                  "turns" (:turns player-data 0)
                }
                "place" {
                  "name" (:place player-data)
                  "exits" (:exits result [])
                }
                "compass" (:compass player-data "")
              } None)))))))


(defn handle-status [auth]
  "Handle status method."
  (let [token (.get auth "session_token" None)]
    (if (not token)
      (make-error ERR-SESSION-NOT-FOUND "Missing session token")
      (let [player-name (verify-token token)]
        (if (not player-name)
          (make-error ERR-SESSION-EXPIRED "Session expired")
          (let [player (get-character player-name)
                account (get-account player-name)]
            (make-response {
              "player" {
                "name" player-name
                "location" (or (.get player "place" {}).name "unknown")
                "score" (or (.get player "score") 0)
                "turns" (or (.get player "turns") 0)
                "online_since" (or (.get account "created_at") (time))
              }
              "world" {
                "name" (config "world" "unknown")
                "players_online" (len _sessions)
                "uptime_seconds" 0
              }
            } None)))))))


(defn handle-online []
  "Handle online method."
  (make-response {
    "players" (lfor [token session] (.items _sessions)
                    {"name" (.get session "player")
                     "location" "unknown"})
    "count" (len _sessions)
  } None))


(defn handle-motd []
  "Handle motd method."
  (make-response {"motd" (engine.motd)} None))


(defn handle-quit [auth]
  "Handle quit method."
  (let [token (.get auth "session_token" None)]
    (if (not token)
      (make-error ERR-SESSION-NOT-FOUND "Missing session token")
      (let [player-name (verify-token token)]
        (if (not player-name)
          (make-error ERR-SESSION-EXPIRED "Session expired")
          (do
            (delete-session token)
            (make-response {"message" f"Goodbye, {player-name}. Thanks for playing."} None)))))))


;; * Request Router
;; -----------------------------------------------------------------------------

(defn :async handle-request [request websocket]
  "Route a JSON-RPC request to the appropriate handler."
  (try
    (let [method (.get request "method" None)
          params (.get request "params" {})
          auth (.get request "auth" {})
          req-id (.get request "id" None)]
      (cond
        (not method)
          (make-error ERR-INVALID-REQUEST "Missing 'method' field" :req-id req-id)
        
        (= method "spawn")
          (await (handle-spawn params websocket))
        
        (= method "parse")
          (await (handle-parse params auth websocket))
        
        (= method "status")
          (handle-status auth)
        
        (= method "online")
          (handle-online)
        
        (= method "motd")
          (handle-motd)
        
        (= method "quit")
          (handle-quit auth)
        
        True
          (make-error ERR-METHOD-NOT-FOUND f"Unknown method: {method}" :req-id req-id)))
    
    (except [e Exception]
      (log.error f"Request handler error: {e}")
      (make-error ERR-INTERNAL "Internal server error"))))


;; * WebSocket Handler
;; -----------------------------------------------------------------------------

(defn :async handle-websocket [websocket path]
  "Handle a WebSocket connection."
  (log.info f"New WebSocket connection from {websocket.remote-address}")
  (try
    (while True
      (let [message (await (.recv websocket))]
        (try
          (let [request (json.loads message)
                response (await (handle-request request websocket))]
            (when response
              (await (.send websocket (json.dumps response)))))
          (except [json.JSONDecodeError]
            (await (.send websocket (json.dumps 
              (make-error ERR-PARSE "Invalid JSON")))))
          (except [e Exception]
            (log.error f"WebSocket error: {e}")
            (break)))))
    (except [websockets.exceptions.ConnectionClosed]
      (log.info "WebSocket connection closed"))
    (finally
      ;; Clean up sessions for this websocket
      (for [[token session] (list (.items _sessions))]
        :when (= (.get session "websocket") websocket)
        (delete-session token)))))


;; * Server
;; -----------------------------------------------------------------------------

(defn :async start-server [[host "0.0.0.0"] [port 8080]]
  "Start the WebSocket server."
  (ensure-config)
  (import websockets.server [serve])
  (print f"Starting WebSocket server at ws://{host}:{port}/ws")
  (log.info f"Starting WebSocket server at ws://{host}:{port}/ws")
  (let [server (await (serve handle-websocket host port))]
    ; Keep server running forever
    (await (.wait_closed server))))


(defn :async serve-async []
  "Main entry point for async server."
  (let [host (or (config "ws_host") "0.0.0.0")
        port (or (config "ws_port") 8080)]
    (await (start-server host port))))


(defn main []
  "Run the WebSocket server."
  (asyncio.run (serve-async)))

(defmain [#* args]
  "Run the WebSocket server."
  (main))
