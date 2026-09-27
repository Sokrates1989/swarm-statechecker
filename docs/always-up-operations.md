# Statechecker always-up operations

This runbook covers the two independent Swarm deployments. The active plan in
`statechecker/plans/active/statechecker-always-up.md` tracks the outage drill,
image rollout, and operator acceptance. A local code change is not evidence
that either server runs the new image.

## Deployment and health

Run `./quick-start.sh` from `/swarm/monitoring/statechecker-server` on IONOS
or `/swarm/administration/statechecker` on Ubuntu Mini. Menu option `1`
deploys the stack, and option `4` checks it. For a read-only health check:

```bash
./quick-start.sh --health
```

Require API, CHECK, database, and Web services at `1/1`, with the public API
and Web endpoints healthy. The one-shot database migration service may show
`0/1` after completion. For a deploy or image update, inspect the API, CHECK,
and Web image references in `docker stack services <stack-name>`; they should
contain `@sha256:`. Menu option `6` or shortcut `i` updates the paired
application images from one version tag. Run option `1` afterward when a
release changes stack settings or secret mounts. Option `1` resolves both
configured tags to digests before stack deploy and leaves the readable tags
in `.env`. If a pull or digest lookup fails, fix it before retrying; do not
replace the images with `latest`.

## Peer ownership and alerts

Ubuntu Mini watches `https://api.statechecker.ionos.fe-wi.com/health`.
IONOS watches `https://api.statechecker.fe-wi.com/health`. Each Websites tab
should contain exactly one peer API sentinel and show **Up** after a checker
cycle. Remove starter examples only after adding the real peer URL.

The worker checks websites every five minutes on both deployments. Inspect
`TELEGRAM_ENABLED` and the error recipient list in each host's private `.env`
locally, and confirm the Telegram sender secret exists by name with the
quick-start secret check. Do not paste bot tokens or complete private
environment files into logs or support requests. A controlled outage and
recovery alert is the delivery test for the intended error channel.

## Emergency API restoration

If an outage drill or scale action does not restore promptly, run only the
matching command on the affected host:

```bash
# IONOS
docker service scale statechecker-server_api=1

# Ubuntu Mini
docker service scale statechecker_api=1
```

Then run `./quick-start.sh --health` in that host's deployment directory and
check its public `/health` URL. Verify the observing host's Websites tab
returns to **Up** after the next checker cycle. A missing alert never
justifies extending an intentional API outage.

## Missing alert response

Restore the API first. Confirm the target health URL and the observer's CHECK
service are healthy. Inspect the observer's checker logs with menu option `5`
or the matching command:

```bash
# Ubuntu Mini observing IONOS
docker service logs --since 20m --tail 200 statechecker_check

# IONOS observing Ubuntu Mini
docker service logs --since 20m --tail 200 statechecker-server_check
```

Check the peer URL, Telegram enablement, configured error recipients, and sender
secret presence without revealing secret values. Record the observed DOWN and
UP AGAIN times, duplicates, and any sender errors for the active plan. If a
new image fails after operator rollout, restore the previously working image
through the image update menu and preserve the database and Swarm secrets.
