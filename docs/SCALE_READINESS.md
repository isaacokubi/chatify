# Scale readiness

## Current assessment

**Not yet verified for high-concurrency production, including a million concurrent users.** The repository is a Flutter client with a Node.js/Express/Socket.IO API and MongoDB Atlas. The available checks are unit and widget tests plus read-only inspection of the connected Atlas catalog. There is no reproducible load-test result, capacity model, staging topology, or production telemetry in this repository. No requests-per-second or concurrent-user capacity is claimed.

## Capacity controls present in code

- User lists, conversations, messages, payments, memories, and many business/school records use bounded pagination.
- MongoDB connection pool sizing is configurable per API process with `MONGODB_MAX_POOL_SIZE` (10–500, default 100); connection, server-selection, and idle-pool settings are bounded.
- Conversation/message indexes, user-owned record indexes, provider references, and payment idempotency constraints are defined in Mongoose schemas. Memory history now has a `{userId, createdAt}` compound index for its normal page query.
- Static Spark and payment content uses Cloudinary/provider boundaries rather than storing large production media in MongoDB. Spark videos are capped at 50 MB and 30 seconds.
- Push delivery is dispatched outside the chat send response path. HTTP and provider calls have bounded payload sizes/timeouts in the relevant modules.

Pool sizing is a per-instance ceiling: `instance count × pool size` contributes to Atlas connections. Raising it without Atlas connection limits, workload measurements, and a deployment plan can make availability worse.

## Blocking architecture and verification work

1. **Realtime horizontal scaling:** the current Socket.IO server has no shared adapter configured. Multiple API processes will not broadcast room events to sockets attached to other processes. Add a managed Redis-compatible Socket.IO adapter, configure load-balancer session affinity (or WebSocket-only routing), and test node loss/reconnect before horizontal scale-out.
2. **Scheduled jobs:** message-expiry and business workflow timers execute in each API process. A multi-instance deployment needs a single scheduler/lease or a durable job queue with idempotent workers.
3. **Media transfer:** Flutter sends selected media through an API request; large base64 video bodies use much more memory and bandwidth than the source file. Use authenticated signed direct-to-object-storage uploads with size/type enforcement before scaling video traffic.
4. **Database:** the owner confirmed the inspected Atlas database is for testing. Read-only inspection reports MongoDB 8.0.34, replica-set topology, 44 collections, and 158 indexes (30 unique). Cluster tier, connection quota, applied schema indexes/validators, working-set size, replication lag, and throughput limits remain unmeasured; test status does not prove production capacity.
5. **Load evidence:** establish representative workload mixes and budgets for login, conversation list/history, send, media upload, business checkout, school fee lookup, callbacks, and background jobs. Run bounded ramp, steady-state, spike and soak tests against isolated staging while observing p50/p95/p99 latency, error rate, CPU/memory, DB connections/slow queries, socket fan-out, queue age, and recovery after node/database interruption.
6. **Production operations:** add shared metrics/traces, alert thresholds, rate limits at the edge, autoscaling bounds, backup/restore drills, and documented rollback. Confirm provider quotas and callback retry behavior with each provider.

## Required next steps

- Identify and provision isolated staging infrastructure with a Redis adapter, Atlas capacity comparable to intended production, and representative synthetic data.
- Add load-test scripts and explicit SLOs; record the exact commit, environment shape, test mix, duration, peak concurrency/RPS, achieved latency/error percentiles, and resource utilization.
- Fix every measured bottleneck and rerun the test after the last code or infrastructure change.
- Validate cross-instance Socket.IO delivery, single-execution scheduled jobs, autoscaling, graceful shutdown, and restore/recovery under controlled failure tests.

Until these checks are completed, scale readiness remains **BLOCKED / NOT MEASURED**. A passing functional suite does not establish capacity for millions of users.
