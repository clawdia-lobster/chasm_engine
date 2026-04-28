"
Server status tracking and reporting.
"

(require hyrule [assoc])
(import time [time])
(import asyncio)

(import chasm_engine [log])

;; Server status
;; -----------------------------------------------------------------------------

(setv server-status {
  "started_at" None
  "ready" False
  "players_online" 0
  "players_total" 0
  "messages_processed" 0
  "errors" 0
  "last_activity" None
  "background_tasks" {
    "extend_world" False
    "develop" False
    "spawn_characters" False
    "spawn_items" False
  }
})

(defn init-status []
  "Initialize server status."
  (setv server-status.started_at (time)
        server-status.ready False
        server-status.players_online 0
        server-status.players_total 0
        server-status.messages_processed 0
        server-status.errors 0
        server-status.last_activity (time)))

(defn set-ready! []
  "Mark server as ready for players."
  (setv server-status.ready True)
  (log.info "Server ready for players"))

(defn increment-messages! []
  "Increment messages processed counter."
  (setv server-status.messages_processed (inc server-status.messages_processed)))

(defn increment-errors! []
  "Increment error counter."
  (setv server-status.errors (inc server-status.errors)))

(defn update-players-online! [count]
  "Update players online count."
  (setv server-status.players_online count))

(defn update-last-activity! []
  "Update last activity timestamp."
  (setv server-status.last_activity (time)))

(defn set-background-task-running [task-name]
  "Mark a background task as running."
  (when (in task-name (.get server-status "background_tasks" {}))
    (assoc (.get server-status "background_tasks") task-name True)
    (log.info f"Background task started: {task-name}")))

(defn set-background-task-stopped [task-name]
  "Mark a background task as stopped."
  (when (in task-name (.get server-status "background_tasks" {}))
    (assoc (.get server-status "background_tasks") task-name False)
    (log.info f"Background task stopped: {task-name}")))

(defn get-status []
  "Return current server status dict."
  server-status)

(defn status-summary []
  "Return a human-readable status summary."
  (let [uptime (- (time) server-status.started_at)
        uptime-mins (// uptime 60)
        uptime-secs (% uptime 60)]
    f"Server status: ready={server-status.ready} | players={server-status.players_online} | messages={server-status.messages_processed} | errors={server-status.errors} | uptime={uptime-mins}m{uptime-secs}s"))
