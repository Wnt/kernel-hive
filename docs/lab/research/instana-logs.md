# Instana and OTLP logs — what the docs actually say

Read from the offline copy at `/home/wnt/instana-docs` on 2026-09-01, for the
log plane (`scripts/serve/logs.py`, `scripts/observability/instana_logs.py`).
Everything below is quoted with a file and line; where the docs do not answer a
question this page says **docs silent** rather than guessing, because two of the
silences are load-bearing for how we batch.

## 1. The endpoint exists, and takes JSON

`0307-opentelemetry-signals.md:285-296` (diagram labels for both hops — app to
agent, and app to backend):

> otlp/gRPC: 4317 / otlp/HTTP: 4318 / content-type: application/x-protobuf,
> application/json / **HTTP endpoint path: /v1/logs**

`0307-opentelemetry-signals.md:271-274`:

> "the OpenTelemetry logs are ingested to the Instana backend by using the
> following ways: 1. Send logs to the Instana backend otlp-acceptor directly
> with the OTLP protocol or through the OpenTelemetry Collector. 2. Ingest logs
> with the Instana agent that collects the data for Instana."

`0307:1641-1643`:

> "The Instana agent and Instana backend (OTLP-Acceptor) support these input
> types through the `otlphttp` and `otlp` exporters. **Sending logs directly to
> the Instana agent improves support for log message correlation with their
> emitter entities**, such as containers, pods, and hosts."

That last sentence is why our forwarder's default destination — the local agent
on `127.0.0.1:4318` — is the better leg for logs specifically, not just for
traces. The agent binds loopback only (`0305-collectors.md:727`).

## 2. The correlation fields are the plain OTLP ones

`0307-opentelemetry-signals.md:330-337`:

> "The following fields are used to transform OpenTelemetry log data for
> Instana:
> - The **TraceId, SpanId, and Body fields are incorporated without any
>   alterations.**
> - The Timestamp field that is considered for logging is the timestamp during
>   the ingestion of log records into Instana.
> - The log level is determined primarily by the SeverityText field and the
>   SeverityNumber field as a fallback. If no log level can be identified from
>   the SeverityText and SeverityNumber fields, then the log level is set to
>   UNKNOWN.
> - The Resource field is used to identify the entity, I/O stream, and host
>   information associated with the log.
> - The Attributes are supported as key-value pairs through the Custom Tags
>   from Instana.
> - The exception attributes `exception.type`, `exception.message`, and
>   `exception.stacktrace` in the Attributes field are also supported in
>   Instana."

**This is the whole finding.** There is no Instana-specific correlation field:
the ids we already mint are the ids it joins on, so a log record shipped with
`traceId`/`spanId` is reachable from the trace we already ship. The last bullet
is also why our stacks travel as `exception.stacktrace` and not under a name of
our own.

Note the timestamp bullet: Instana stamps on INGEST. Our own store keeps both
`ts_ms` (the producer's clock) and `observed_ms` (ours), so the question
"was the record late or was the event late?" stays answerable here even though
it is not answerable there.

The pivot, both directions, `0015-quick-start-guides.md:446-457`:

> "**Instana automatically links log messages to their corresponding traces** …
> To view logs for a specific request: 1. Go to **Analytics > Applications >
> Calls**. 2. Find and click the request … 3. **Click the Logs tab to see all
> log messages generated during this request.** To search logs and find related
> traces: 1. Go to **Analytics > Logs** … 3. **Click a log message, then click
> the trace ID to see the complete request flow.**"

Query-side, the log tag is `log.traceId` — "Trace ID associated with the log
entry" (`0248-logging.md:933-934`). There is **no `log.spanId` tag** in the
Logging API's tag list (`0248:880-936`), even though span ids are ingested and
billed (`0248:704-705`). So a span-level filter is doable in our store and, as
far as the docs go, not in theirs.

## 3. Host identity is REQUIRED, not decorative

`0307-opentelemetry-signals.md:338-352`:

> "**Host or entity identification is required for Instana to accept
> OpenTelemetry logs.** To meet this requirement, use one of the following
> options: 1. Configure one of the following attributes in the Resource field
> of the logs: `process.id`, `faas.id`, `service.instance.id`, `container.id`,
> `aws.ecs.container.arn`, `k8s.job.uid`, `k8s.cronjob.uid`, `k8s.pod.uid`,
> `k8s.node.uid`, `device.id`, `host.id`. 2. Set the `x-instana-host` header."

Direct-to-backend narrows it (`0308-sending-opentelemetry-data-to-instana.md:205`):

> "The Instana backend requires the `host.id`, `faas.id`, or `device.id`
> resource attribute. Alternatively, you can set `x-instana-host` as an
> environment variable."

`logs_otlp.export` puts both `host.id` and `service.instance.id` in the
resource, and the forwarder already sets `x-instana-host` on the leg that needs
it — so all three doors are covered. `service.name` is NOT required for ingest;
it is what correlates a log to a SERVICE (`0307:1693`).

## 4. Limits — one measured, several silent

- **Agent message size is configurable, floor 5 MB** —
  `0003-agents.md:1609-1614`: "HTTP message size limits can now be configured
  by using `INSTANA_AGENT_OTEL_HTTP_MAX_MESSAGE_SIZE` … (minimum: 5 MB,
  maximum: 49.5 MB)". Our probe measured this agent accepting up to 5,242,880
  bytes exactly and closing the connection above it — i.e. it runs at the
  documented floor. `instana_batch.MAX_BODY_BYTES` is 4 MiB, 80% of that.
- **Compression**: "The OTEL Collector supports only the gzip compression
  algorithm for sending OTEL payloads to Instana." — `0307:1679`.
- **Per-LogRecord or per-request body cap on the backend acceptor** — **docs
  silent.**
- **Rate limits, throttling, HTTP 429** — **docs silent.** The only adjacent
  statements are commercial (`0321-policies.md:106-110`, a data-ingest fair-use
  policy) and query-side sampling (`0248:295-296`), neither of which is an
  ingest limit.
- **Accepted methods, response codes, partial-success semantics of `/v1/logs`**
  — **docs silent.** The path appears only as diagram label text; there is no
  prose endpoint spec and no curl example for posting OTLP logs anywhere in the
  tree.
- **A SeverityNumber → level mapping table** — **docs silent** beyond the
  "SeverityText primary, SeverityNumber fallback, else UNKNOWN" rule above.

Because two of those silences are exactly the ones a batcher needs, the logs
leg reuses the measured trace-lane budgets unchanged rather than inventing a
limit the docs do not support, and keeps the same halve-and-retry on a
size-shaped refusal.

## 5. Retention there, and what we chose here

`0321-policies.md:89-90`:

> "**Logs: All the collected logs are kept for 7 days.** With Extended log
> retention, you can retain logs for 30, 60, and 90 days, compared to the 7
> days of default retention time of Instana core logging feature."

`0275-logging.md` adds that on SaaS, **OpenTelemetry logs need a logging add-on**
("OpenTelemetry logs — Yes [add-on required] — Based on selected entitlement"),
while "Your standard Instana license includes log ingestion for on-premises
deployments."

So: if this tenant has no logging add-on, the `/v1/logs` leg may be accepted and
retained for nothing, or refused. That is a tenant question, not a code
question, and the leg reports its status per run either way.

Our own store keeps **7 days**, matching the default above, so both stores
answer a question for the same window. Instana also meters log volume on
content rather than wire bytes, and explicitly counts what we send:
"All attached custom tags / Trace IDs / Span IDs / Information that is related
to exceptions" (`0248:700-706`).
