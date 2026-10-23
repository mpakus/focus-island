# Jira Cloud API research for Focus Island

Checked against official documentation on **October 23, 2026**. This API research used public documentation only; no credentials were read and no Jira changes were made. The accompanying [integration plan](JIRA-INTEGRATION-PLAN.md) records the separate connected-account feasibility check and the chosen implementation scope. Jira Data Center is outside this proposal.

## Recommendation and the authentication decision

Start with a small, read-only personal feasibility test and a local import flow: fetch assigned work, let the user select issues, then attach their Jira identity to ordinary Focus Island tasks. Keep Focus Island scheduling, focus sessions, and completion under local control. The HTTP/data mapping work is straightforward; authentication for a distributed desktop application is the principal design constraint.

| Situation | Supported evidence and proposed approach |
| --- | --- |
| Owner's personal API experiment | Atlassian documents email plus API-token Basic authentication for personal scripts and ad-hoc calls. Use a scoped, expiring token for the private experiment. This is not evidence that a distributed token-entry UI is acceptable. [Basic authentication](https://developer.atlassian.com/cloud/jira/platform/basic-auth-for-rest-apis/) |
| Distributed Focus Island integration | Atlassian directs integrations to one distributable OAuth 2.0 authorization-code/3LO app and explicitly says apps collecting API tokens or asking customers to create individual 3LO apps do not comply with its cloud-app security requirements and acceptable-use policy. [3LO guide](https://developer.atlassian.com/cloud/jira/platform/oauth-2-3lo-apps/) |
| Backend-free desktop OAuth | The documented Jira Cloud exchange and refresh requests require `client_secret`; the guide does not document a public-client PKCE alternative. Therefore a secure, backend-free Jira 3LO flow is **not established by this research**. Confirm support with Atlassian before committing to that architecture. Otherwise plan a confidential OAuth broker. [3LO guide](https://developer.atlassian.com/cloud/jira/platform/oauth-2-3lo-apps/) |

Do not embed an app-wide OAuth secret in the Swift app or repository. Native applications cannot keep such a distributed secret confidential; public native OAuth clients require PKCE and an external browser authorization flow. A broker is an architectural option requiring its own session, callback, token-storage, and abuse-prevention design, not an implementation detail to hide inside the current local-only scope. [RFC 8252, sections 6 and 8.5](https://www.rfc-editor.org/info/rfc8252/)

For a scoped API token, send Basic authentication to `https://api.atlassian.com/ex/jira/{cloudId}/rest/api/3/...`, not the site-specific API URL used by unscoped tokens. Token lifetimes are selectable from 1–365 days; replacement and revocation must be expected. [API-token documentation](https://support.atlassian.com/atlassian-account/docs/manage-api-tokens-for-your-atlassian-account/)

For the personal experiment, the Cloud ID can be retrieved from `https://<site>.atlassian.net/_edge/tenant_info`, as documented by Atlassian Support. For 3LO, discover authorized sites through `GET https://api.atlassian.com/oauth/token/accessible-resources` and let the user select the intended site. [Cloud-ID lookup](https://support.atlassian.com/jira/kb/retrieve-my-atlassian-sites-cloud-id/), [OAuth API routing](https://developer.atlassian.com/cloud/oauth/getting-started/making-calls-to-api/)

## Read API contract

Use `POST /rest/api/3/search/jql`. The old `/rest/api/3/search` route has been removed according to Atlassian's support migration guide. Cursor pagination replaces `startAt`. [Search migration guidance](https://confluence.atlassian.com/jirakb/run-jql-search-query-using-jira-cloud-rest-api-1289424308.html)

Suggested initial request:

```json
{
  "jql": "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC",
  "fields": ["summary", "status", "project", "assignee", "updated"],
  "maxResults": 100
}
```

This combines the authenticated-user function with the workflow category instead of assuming every project has a status named Closed. Optional project filtering can narrow the search later. Jira's default “My open issues” filters have historically used different definitions, so the UI should state the selected rule. [Official JQL examples](https://support.atlassian.com/jira-software-cloud/docs/example-jql-queries-for-board-filters/), [Atlassian's documented filter discrepancy](https://jira.atlassian.com/browse/JRACLOUD-85015)

The search API requires a bounded JQL query and returns IDs only unless fields are requested. `maxResults` is a requested ceiling, not a promise; responses may contain fewer items. Follow each opaque `nextPageToken` sequentially with the same query and fields, checking `isLast`. Never infer completion from a short page. The schema says the last page has a null token. Treat a non-final page with a missing or repeated token as an incomplete refresh. [Official OpenAPI schema](https://dac-static.atlassian.com/cloud/jira/platform/swagger-v3.v3.json)

Recommended classic scopes:

| Call | Read scope |
| --- | --- |
| `POST /rest/api/3/search/jql` | `read:jira-work` |
| `GET /rest/api/3/issue/{issueIdOrKey}` | `read:jira-work` |
| `GET /rest/api/3/myself` to verify and retain the connected account ID | `read:jira-user` |

These are the smallest **classic scope set** for these calls, not a claim of the narrowest possible granular permissions. Atlassian recommends classic scopes; its enhanced GET and POST search references currently list different granular sets. Do not guess one granular scope from a field name. No write, project-admin, board, or sprint scope is needed for this design. [Scope guidance](https://developer.atlassian.com/cloud/jira/platform/scopes-for-oauth-2-3LO-and-forge-apps/), [Search scopes](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issue-search/#api-rest-api-3-search-jql-post), [Issue scopes](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issues/#api-rest-api-3-issue-issueIdOrKey-get), [Current-user scopes](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-myself/#api-rest-api-3-myself-get)

Scopes do not grant project visibility. Search includes only issues permitted by project browsing and issue-security rules and is subject to app-access policies. An empty result is not proof that the account has no assigned work anywhere. [Search permissions](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issue-search/#api-rest-api-3-search-jql-post)

## Identity, reconciliation, and field ownership

Recommended link identity is `(cloudId, issue.id)`, retaining the numeric-looking API ID as a string. Store the latest issue key separately for display. Keys can change after project/space-key changes, and Get Issue resolves moved issues and returns their current key. Do not deduplicate by summary or key alone. Cross-site migrations are outside this identity guarantee and need explicit relinking. [Key changes](https://support.atlassian.com/jira-software-cloud/docs/edit-a-projects-details/), [Get Issue behavior](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issues/#api-rest-api-3-issue-issueIdOrKey-get)

Search is eventually consistent. `reconcileIssues` accepts at most 50 issue IDs and strengthens read-after-write consistency only for those IDs; it does not return issues that fail the JQL. It is therefore not a solution for discovering that an imported issue has been completed or reassigned. [Search and reconcile](https://developer.atlassian.com/cloud/jira/platform/search-and-reconcile/)

One possible refresh algorithm (the integration plan uses independent discovery and linked-issue refresh actions):

1. Fetch the complete assigned-issues result into a temporary snapshot; deduplicate by site and issue ID.
2. Refresh previously linked board issues absent from that snapshot with `GET /issue/{id}`, requesting only the same small field set. This lets completed or reassigned issues update their Jira badge without satisfying the import filter.
3. A denied or missing issue becomes “unavailable” without inferring deletion; retain the local task and focus history. A network failure leaves its previous Jira data stale.
4. Publish the new inbox snapshot only after every search page succeeds. Never remove local board tasks because search omitted them, an account disconnected, or a request failed.
5. Keep Jira status and local task completion separate. Refresh remote metadata without overwriting local notes, scheduling, ordering, or running sessions. Completing a local task makes no Jira request.

These are application design recommendations, not Jira-provided synchronization semantics.

## Descriptions, failures, and verification limits

REST v3 descriptions support Atlassian Document Format (ADF), a structured JSON document. The smallest alternative is to omit descriptions and provide “Open in Jira.” The integration plan instead includes a bounded plain-text conversion for selected and linked issues. Decode ADF explicitly and preserve local notes separately; do not cast the description to a plain string or render arbitrary returned HTML. [REST v3 format](https://developer.atlassian.com/cloud/jira/platform/rest/v3/intro/#version), [ADF structure](https://developer.atlassian.com/cloud/jira/platform/apis/document/structure/)

On HTTP 429, honor `Retry-After` and use bounded exponential backoff with jitter. Transient 503 responses may also include that header. Serialize refreshes, request only needed fields, and show cached data with last-success time during failures. Authentication/permission failures require a useful reconnect/access message rather than repeated retries. API-token and OAuth traffic have different rate-limit regimes; do not hard-code one universal quota. [Rate limiting](https://developer.atlassian.com/cloud/jira/platform/rate-limiting/)

Before implementation is considered validated, check the actual site's Cloud/Data Center deployment, permitted authentication, available token scopes, assigned-issue volume, workflow categories, and multi-page responses. Exercise reassignment/completion, key changes, lost permissions, token expiry, interrupted pagination, and cancellation on account switch. No live credentials, tenant calls, OAuth registration, native callback, or runtime behavior were tested here. Public-native Jira Cloud OAuth support remains an explicit open question.
