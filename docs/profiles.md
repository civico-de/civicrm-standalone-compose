# Public profiles

Caddy decides for every request who may reach CiviCRM, in this order:

1. Static files under `/core/`, `/ext/` and `/public/` (never PHP), and the scripts and
   styles CiviCRM generates under `/civicrm/asset/builder`: everyone.
2. The routes of the profiles listed in `PUBLIC_PROFILES`: everyone.
3. Anything else: only the addresses in `ADMIN_IPS`.
4. Everyone else gets `403` with the body `Forbidden`.

A profile only decides which requests reach CiviCRM. What a visitor may do there is still
up to CiviCRM's permissions. Anonymous visitors get the permissions of the `everyone` role,
which you edit at `civicrm/admin/roles`.

Profiles are files in `caddy/profiles/`. Change `PUBLIC_PROFILES` in `.env` and apply
it with `docker compose up -d`. After editing a profile file, `docker compose restart caddy`
is enough.

## Built-in profiles

### `forms`

Opens pages under `/civicrm/form/` and the APIv4 actions `Afform.prefill`, `Afform.submit`
and `Afform.submitFile`.

In FormBuilder, give the form a URL starting with `civicrm/form/` and let anonymous users
open it. Fields that search existing records (autocomplete) call further APIv4 actions that
this profile does not open.

### `civimail`

Opens the links in mailings: click tracking, open tracking, view in browser, unsubscribe,
opt-out, subscription confirmation and resubscribe. It also opens the images of Mosaico
templates. The subscribe form under `/civicrm/mailing/subscribe` stays closed; build sign-ups
with FormBuilder and the `forms` profile.

### `events`

Opens:

- the event list, event pages and their registration forms;
- the iCalendar feed;
- the links in event mails, for confirming a place from the waiting list or after approval,
  and for cancelling or transferring a registration;
- the state and county lists that address fields load.

Participant lists (`/civicrm/event/participant`) stay closed.

`everyone` may view events and register by default. If the registration form includes
profiles, also give `everyone` the permission *CiviCRM: profile create*. Without it the
registration page answers with an error.

### `contributions`

Opens:

- contribution pages;
- the billing block, which the page reloads when the visitor picks another payment method;
- the state and county lists;
- payment processor notifications under `/civicrm/payment/ipn`;
- the links in receipts for recurring contributions: cancel, update billing details,
  change the amount.

The contribution screens of the back office stay closed, and so do personal campaign pages
and the contribution widget.

`everyone` may make online contributions by default. Profiles on the page need
*CiviCRM: profile create*, as for events. Payment processors from extensions may send their
notifications to their own routes. Check the extension's documentation, and add those
routes as your own profile.

### `api`

Opens all of APIv4 (`/civicrm/ajax/api4/<Entity>/<action>`), but only for requests with an
`X-Civi-Auth: Bearer <API key>` header. Requests without it never reach CiviCRM through this
profile. For a wrong key, CiviCRM answers `401`. A valid key runs the call with the
permissions of the user the key belongs to. APIv3 stays closed.

Setting up a system that calls the API:

1. Create a role at `civicrm/admin/roles` with *CiviCRM: authenticate with api key* and only
   the permissions the system needs. Reading events, for example, takes *CiviEvent: access
   CiviEvent* and *CiviEvent: view event info*.
2. Create a user with that role at `civicrm/admin/users`.
3. Give the user's contact an API key. CiviCRM has no screen for it:

   ```sh
   openssl rand -hex 32
   docker compose exec -u www-data app cv api4 Contact.update +w id=<contact ID> +v api_key=<key>
   ```

A call then looks like this:

```sh
curl -X POST https://crm.example.org/civicrm/ajax/api4/Event/get \
  -H 'X-Civi-Auth: Bearer <key>' \
  --data-urlencode 'params={"select":["id","title","start_date"],"where":[["is_public","=",true]]}'
```

## Your own profile

A profile is a named path matcher and a `handle` block. This one lets a website read events
through the API with its key, and nothing else:

```
# caddy/profiles/website.caddy
@website {
	path /civicrm/ajax/api4/Event/get
	header_regexp X-Civi-Auth "^Bearer [^ ]"
}
handle @website {
	reverse_proxy app:80
}
```

Save it in `caddy/profiles/`, add `website` to `PUBLIC_PROFILES` and run
`docker compose up -d`. The matcher name must not repeat across profiles; Caddy refuses to
start otherwise, and it does the same for a name in `PUBLIC_PROFILES` without a file.
Files you add yourself are yours. Updates of this repository do not touch them.

To find the paths a page needs, open it from an address outside `ADMIN_IPS`, for example
a phone on mobile data, with the browser's developer tools showing network requests. Caddy
has refused every request that answers `403` with the body `Forbidden`. Anything else came
from CiviCRM. The routes of CiviCRM and of its extensions are listed in their
`xml/Menu/*.xml` files, including the permission each route asks for.

Some rules keep a profile tight:

- **Open exact paths.** CiviCRM decides by path alone and ignores the query string, so an
  exact path opens exactly one page.
- **Open single APIv4 actions** such as `/civicrm/ajax/api4/Afform/submit` for anonymous
  visitors. The entity and action are part of the path, so each one can be opened by itself.
- **Never open `/civicrm/ajax/rest`.** APIv3 carries the entity and the action in the request
  body, where a path matcher cannot see them.
- **Never open PHP files** under `/core/` or `/ext/`. The static-file rule excludes them on
  purpose.

Extensions you install into the `ext` volume bring their own routes. Their public pages and
notification endpoints stay closed until a profile opens them.
