# What PocketPiggies needs for linking from the Steward app

PocketPiggies' assistant link protocol (its `docs/ASSISTANT_API_SPEC.md`, section 7, PR 140) binds every client, link and grant to a Telegram chat.
The household has retired Telegram, and other households will never have it, so the key holder now also speaks a second binding: the household person the Steward app names.
This is what PocketPiggies' server has to accept for that binding.
Nothing here changes for the two Telegram-bound clients that exist today.

`tests/pocketpiggies_fake.py` accepts both bindings exactly as described here, and `tests/test_pocketpiggies_keyholder.py` runs the real key holder against it, so it doubles as a reference for the server's side.

## Bindings

| | Telegram binding (today) | Household binding (new) |
| --- | --- | --- |
| Who | the owner's private Telegram chat | the household person the gateway's app belongs to, `franco`, `marina` |
| Client id | `corey` or `denise`, fixed | issued per household gateway, see [Clients](#clients) |
| Link body | `telegramUserId`, `chatId`, `chatType: "private"` | `subjectType: "household_person"`, `subject: "<person id>"` |
| Read headers | `X-PocketPiggies-Telegram-User-Id`, `-Chat-Id`, `-Chat-Type: private` | `X-PocketPiggies-Subject-Type: household_person`, `X-PocketPiggies-Subject: <person id>` |
| Back after consent | `https://t.me/<bot>` | `steward://pocketpiggies/linked` |

Every request still carries `X-PocketPiggies-Client-Id` on reads and the client credential as the bearer on link calls, exactly as now.
A key holder uses one binding for everything: it is the Telegram binding when its drop-in names `POCKETPIGGIES_TELEGRAM_ID`, and the household binding otherwise (`household/pocketpiggies/binding.py`).

A person id is lowercase letters, digits and hyphens, starting with a letter, at most 32 characters.
It is unique only within its household, so PocketPiggies must always read it together with the client id.

## Clients

Today `ASSISTANT_LINK_CLIENTS` holds two entries, each with a credential digest, a Telegram id and a bot name.
A household-bound client's registration, as `pocket-piggies-install.py --provision-client` prints it, is:

```json
{
  "clientId": "hh-7f3a",
  "credentialSha256": "<64 hex characters>",
  "subjectType": "household_person",
  "subject": "marina",
  "redirectUri": "steward://pocketpiggies/linked"
}
```

What the server needs:

1. **A client entry with a subject in place of a Telegram id and bot.**
   Its redirect URI is `steward://pocketpiggies/linked`, the same for every household.
2. **Client ids that never collide.**
   `corey` and `denise` are taken, and another household's assistants may well have the same names, so the id comes from PocketPiggies: issue one per gateway at registration (for example `hh-` and four random hex characters) and give it back to whoever registers it; the household passes it to the installer as `--client-id`.
3. **Optional, for more households: registering a client without a deploy.**
   An entry in the environment needs PocketPiggies redeployed for each household.
   A settings page where the signed-in PocketPiggies owner pastes the registration above, and which stores the client against their account, lets a household connect without Franco in the loop.
   Until then Franco registers each household's clients by hand, as he did Corey's and Denise's.

## Link requests, exchange and revoke

`POST /api/assistant/link/requests`, `/exchange` and `/revoke`, unchanged apart from who they are for:

- For a household-bound client, require `subjectType: "household_person"` and a `subject` equal to the client's registered subject; refuse the Telegram fields for it with `invalid_binding`.
- For a Telegram-bound client, keep today's checks and refuse the subject fields.
- Accept `redirectUri` only if it is the client's registered one.

The PKCE flow, the request lifetime, the attempt limits and the answers stay as they are; the key holder already handles every code PocketPiggies returns.

## The consent page

After the owner allows or denies, the page sends them to the client's redirect URI.
`steward://` is a custom scheme, which browsers will not always follow on their own, so the page should show a **Return to Steward** button pointing at `steward://pocketpiggies/linked?request=<request id>` as well as trying it automatically.
The request id is not a credential: finishing a link still needs the key holder's PKCE verifier.

The owner does not need the redirect to work at all.
Back in their thread they send `/pocketpiggies status`, which finishes a pending link (`AccountLink.status` in `household/pocketpiggies/link.py`); the app can send it for them when it opens that link.

## Grants and reads

A grant made under the household binding is bound to its client and subject:

- `GET /api/assistant/catalog`, `/records/{table}`, every functional read and `POST /api/assistant/sync` with such a grant require `X-PocketPiggies-Subject-Type: household_person` and the grant's subject in `X-PocketPiggies-Subject`, and refuse the Telegram headers, with `assistant_scope_denied`.
- A Telegram-bound grant keeps requiring the Telegram headers.
- Scope, lifetime (at most 181 days), the read-only table and everything else about a grant stay as they are.

## Moving Franco and Gia to the household binding

Not needed for anything to work: their key holders keep the Telegram binding (`--telegram-id`), and linking under it works with today's server, apart from PocketPiggies sending them to Telegram after consent, from where they come back to Steward and send `/pocketpiggies status`.

Once the server accepts the household binding, either can move:

1. Revoke the old grant: `/pocketpiggies disconnect` in their thread.
2. Stop the key holder and move its state file aside: `systemctl stop household-pocketpiggies@corey`, then `mv /var/lib/household-pocketpiggies/corey/connection.json{,.telegram}`.
   A state file written under one binding is never read under the other.
3. `pocket-piggies-install.py corey --owner franco --client-id <the new id> --restart`, without `--telegram-id`, then `--provision-client`, and register what it prints.
4. `/pocketpiggies connect` in Franco's thread.
