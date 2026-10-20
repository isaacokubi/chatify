# Chatify: 100M-user scalability and reliability plan

Status: engineering plan and acceptance gates, not evidence that the system currently supports 100 million users.

## Current architecture audit (main, 2026-10-20)

The current API is a single Node.js/Express process with Socket.IO and Mongoose. The API entry point defines core schemas and business routes, and connects to MongoDB Atlas. This is a useful starting point but is not a horizontally scalable deployment by itself.

Observed scale risks in the current code:
- Socket.IO presence is held in a process-local `Set`; it is not shared between API instances.
- A new socket loads every conversation in which the user participates and joins each conversation room. This can cause large database reads and long connection setup for highly connected accounts.
- Real-time events use the default Socket.IO adapter, so room broadcasts do not automatically cross multiple API instances.
- Rate limiting uses the default in-memory store; limits are per process and reset on restart.
- Message expiry runs as a timer in each API process. Multiple replicas can compete to process the same work and scan the due-message query independently.
- The API uses offset pagination (`skip`) for memories and has several embedded arrays on growing records. Deep offsets and unbounded per-document arrays can become expensive.
- The main entry point includes many routes and schemas in one large module, making isolated scaling, performance testing and fault containment harder.
- Existing health endpoints only indicate basic API/database availability. They do not demonstrate latency SLOs, saturation, queue lag, or recovery behavior.
- The codebase documents backup scripts, but a documented script is not proof of automated off-site backups or a successful restore drill.

These findings mean 100M-user capacity is **not established**. They do not imply that current deployments are unusable at their present scale.

## Target architecture

1. **Stateless API tier:** multiple independently deployable API instances behind a load balancer; externalize sessions, distributed rate-limit state and presence. Add readiness/liveness checks, graceful draining, autoscaling and per-instance resource limits.
2. **Realtime tier:** Socket.IO Redis adapter (or a dedicated realtime gateway) for cross-instance rooms; Redis-backed presence with TTLs and multi-device semantics. Do not load/join every historical conversation at socket connect. Authenticate first, then subscribe only to active/recent conversations and authorize every subscription.
3. **MongoDB Atlas:** production-sized replica set/sharded cluster selected from measured workload; explicit index migrations managed separately from application startup; query-plan review; bounded documents; cursor/keyset pagination; connection-pool budgets per API replica; workload isolation for analytics and background jobs. Sharding keys must be selected from measured access patterns and tested for hotspot risk, not guessed in advance.
4. **Asynchronous work:** durable queue and worker pools for push notifications, media processing, exports, billing reconciliation and expiry cleanup. Jobs need idempotency keys, bounded retries, exponential backoff, dead-letter handling and queue-lag alerts. Do not rely on per-process timers for distributed jobs.
5. **Media and delivery:** keep large binary content out of MongoDB; use object storage/CDN, image variants, cache headers and signed URLs where private media is required. Use FCM for push and keep transient typing/presence separate from durable messages.
6. **Resilience:** multi-zone managed database deployment, automated encrypted backups, point-in-time recovery where supported, isolated restore drills, tested RPO/RTO, provider timeouts, circuit breakers and bounded retries. Avoid retry storms and do not acknowledge payment success until a verified provider callback/reconciliation confirms it.
7. **Observability:** request IDs and structured logs; metrics for p50/p95/p99 latency, error rates, event-loop lag, memory, socket counts, connection-pool wait, slow queries, database CPU/IOPS, replication lag, queue lag, payment callback age and notification delivery. Add alerting and incident runbooks.
8. **Security and tenancy:** server-enforced membership and organization scope on every read/write; rate limits shared across replicas; secrets from a secret manager; least-privilege database users; audit logs; tested backup access controls and restore permissions.

## Database work required before large-scale launch

- Capture representative query shapes from REST routes, socket startup, conversation history, contacts, memories, stores, school fees and payment reconciliation.
- For every hot query, record an `explain("executionStats")` baseline and verify index selectivity and documents examined versus returned.
- Add indexes through an explicit migration job, review disk/write overhead, and deploy indexes before application code relies on them. Never drop production indexes or rebuild the production database as a shortcut.
- Ensure message history queries use `conversationId + createdAt + _id` cursor pagination; avoid large `skip` offsets.
- Bound reactions, receipts, push tokens, participants and other arrays. Move high-cardinality delivery/read receipts and audit events to dedicated collections or a purpose-built store when measurements show document growth is a bottleneck.
- Add unique/idempotency constraints for payment provider references, webhook events, and background jobs. Test duplicate, delayed, out-of-order and mismatched callbacks.
- Test account deletion, retention, message expiry and archival policies at realistic collection sizes.
- Budget MongoDB connection pools across all API replicas and worker processes. Do not increase per-process pool sizes without calculating the total against Atlas connection limits.

## Load and failure testing gates

Run load tests against an isolated staging environment with production-like indexes and synthetic data. Never run destructive or high-volume tests against the production database.

Required scenarios:
- Ramp up REST logins, paginated history reads, sends, contacts and store/catalogue searches.
- Hold concurrent Socket.IO connections, reconnect storms and multi-device sessions.
- Run mixed read/write workloads while workers, payment callbacks and notifications are active.
- Inject MongoDB latency/failover, Redis unavailability, provider timeouts, worker crashes and deploy/restart events.
- Verify duplicate requests and callbacks remain idempotent and that failed dependencies do not create unbounded queues.
- Run long enough to detect memory leaks, connection leaks, index growth and queue accumulation.

Release gates must be based on an agreed target for active users, concurrent sockets, messages/second, read/write mix, payload sizes and geography. Record p95/p99 latency, error rate, resource headroom, queue lag and recovery time. Scale targets in steps (for example 100, 1k, 10k, 100k concurrent sockets) and only proceed when measured results meet the SLO with headroom. A 100M registered-account target must be converted into realistic peak-concurrency and traffic assumptions before infrastructure sizing.

## Changes implemented on main (2026-10-20)

The following first-stage runtime changes have been committed:
- Socket connection setup and disconnect presence fan-out now query only the 100 most recently updated conversations instead of scanning every historical conversation. Older conversations can still be joined on demand through the existing server-authorized `conversation:join` event.
- Message history and expiry indexes are declared in the schemas, and a separate explicit migration script creates the high-volume indexes without dropping data or indexes.
- The message expiry sweep processes at most 250 due messages per pass and avoids overlapping sweeps within one process. The update remains conditional so multiple API replicas do not expire the same message twice. This is bounded work, not yet a durable queue.
- Memory history supports an opaque cursor for indexed newest-first reads while retaining the legacy page parameters for older clients.
- MongoDB connection pool size and timeouts can be configured with `MONGO_MAX_POOL_SIZE` and `MONGO_MIN_POOL_SIZE`; schema auto-indexing is disabled unless `MONGO_AUTO_INDEX=true`. The new indexes therefore require the explicit migration below.
- Added `/ready` and expanded `/health` with safe readiness and uptime information.

### Apply the new indexes safely

1. Back up the target database and confirm the current `MONGODB_URI` points to the intended environment.
2. Deploy the application code.
3. From `server/`, run `npm run migrate:indexes` against the intended database during a low-traffic window. The script creates only named indexes and does not delete or rewrite records.
4. Verify the indexes with MongoDB `getIndexes()` and compare `explain("executionStats")` for the affected queries.
5. Watch index-build load, database CPU/IOPS, query latency and replication lag. Stop if the database shows unacceptable pressure.

These commits are initial bottleneck reductions, not completion of the 100M-user architecture. Cross-instance Socket.IO adapter/presence, shared distributed rate limiting, durable workers, broad query/index coverage, multi-region infrastructure, and load/failover testing remain outstanding and must not be represented as already delivered.

## Safe implementation sequence

1. Establish a baseline: production-like staging, sanitized representative data, dashboards, query profiling, and repeatable load tests.
2. Fix hot-path query/index/pagination problems and bound growing documents.
3. Move presence and rate-limit state to shared infrastructure; add the Socket.IO adapter and remove connect-time loading of every historical conversation.
4. Move expiry, notifications, media tasks and reconciliation to durable workers.
5. Deploy multiple API replicas, configure health-based autoscaling and graceful draining, and test rolling deployments.
6. Validate backup/restore and regional failure procedures.
7. Increase traffic in controlled load tests, document measured limits, then tune Atlas and autoscaling from evidence.

## Acceptance checklist

- [ ] Current main passes backend tests, lint, Flutter analysis/tests/build and dependency checks.
- [ ] Index migrations are repeatable, non-destructive and verified on staging.
- [ ] Query plans and pagination are tested with large synthetic datasets.
- [ ] Multi-instance socket rooms, presence, revocation and reconnect behavior are tested.
- [ ] Shared rate limits work across instances.
- [ ] Distributed jobs are idempotent, retry safely and expose dead-letter/lag metrics.
- [ ] Payment callback replay and reconciliation tests pass.
- [ ] Load tests meet agreed p95/p99/error-rate SLOs with resource headroom.
- [ ] Backup restoration and failover drills meet the agreed RPO/RTO.
- [ ] Deployment dashboards, alerts and incident runbooks are operational.
- [ ] Results, tested traffic levels, infrastructure costs and remaining limits are recorded.

## Important limitation

This document does not claim the above architecture has been implemented, the database has been migrated, or that a load test has passed. Those claims require code changes, staging infrastructure, repeatable tests and measured results. Do not advertise 100-million-user readiness until these gates are evidenced.


## Additional runtime hardening (2026-10-20)

- Push notifications are now written to a MongoDB-backed outbox with a unique `(recipientId, messageId)` key, atomic worker leases, bounded retries, and a 30-day TTL for completed/terminal job metadata. A process crash can leave a job leased only until its lease expires; delivery is **at least once**, so a crash after provider acceptance can still result in a duplicate push. The queue does not store push tokens; workers reload current preferences/tokens at delivery time.
- Conversation message/read/delivery/reaction/deletion and group-update events are fanned out to participant user rooms as well as the conversation room, so devices not currently subscribed to that room receive updates on a single Socket.IO deployment.
- Apply the new notification outbox indexes using the existing explicit `npm run migrate:indexes` process after a backup during a low-traffic period.

**Still required before horizontal scale-out:** this repository does not yet configure a cross-instance Socket.IO adapter or a shared distributed rate-limit store. Do not add API replicas and assume in-memory rooms, presence, or rate-limit counters are shared. Provision and test shared pub/sub/rate-limit infrastructure, validate high-volume school/business/store queries, then perform staging load/failover tests and a verified backup-restore drill. These code changes alone do not prove 100-million-user capacity.
