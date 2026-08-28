# oracle-sniper

Oracle Cloud's Always Free tier is genuinely generous — 2 Arm OCPUs with 12 GB of RAM, for free, forever. The catch is that in popular regions those machines are almost never available. You fill in the launch form, hit *Create*, and get:

```
Out of host capacity.
```

Capacity does free up, constantly, but in seconds-wide windows as other people's instances get terminated. Whoever asks at the right moment wins. That is not a job for a human refreshing a browser tab.

**oracle-sniper** asks for you. It runs on any Linux box you already own, retries on a schedule across every availability domain in your region, stops itself the moment it succeeds, and tells you where your new machine is.

```
[2026-08-22 06:19:59] AbCd:EU-FRANKFURT-1-AD-1: no capacity.
[2026-08-22 06:20:01] AbCd:EU-FRANKFURT-1-AD-2: no capacity.
[2026-08-22 06:20:04] AbCd:EU-FRANKFURT-1-AD-3: no capacity.
[2026-08-22 06:20:04] No luck this round.
...
[2026-08-22 09:41:12] SUCCESS: 'docker-a1' created in AbCd:EU-FRANKFURT-1-AD-3.
[2026-08-22 09:41:31] Public IP: 203.0.113.47
[2026-08-22 09:41:31] Timer disabled.
```

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/brightcolor/oracle-sniper/main/install.sh | sudo bash
```

The installer walks you through everything, verifies your API access before writing anything permanent, and offers to start the timer at the end. Re-running it later is safe — it offers to keep your existing configuration.

### Requirements

Nothing you have to install first, on any mainstream distribution:

- `bash`, `curl`, `openssl`, `flock`, `base64`
- `systemd` (for the timer)
- An Oracle Cloud account with a VCN and a subnet already created

No Python, no OCI CLI, no SDK, no package installs. Requests are signed with `openssl` directly. The whole thing is about 20 KB of shell and idles at zero cost — a run takes roughly one second of CPU time and is capped at 64 MB of memory, so it is at home on the smallest VPS you have lying around.

---

## What the installer asks

| Step | What it needs | Notes |
|---|---|---|
| 1. Credentials | User OCID, tenancy OCID, region | Oracle shows all of these in one snippet when you add an API key |
| 2. API key | Reuse one, point at one, or generate a fresh RSA key | It prints the public half and the fingerprint for you to register |
| 3. Verification | — | Lists your availability domains; nothing is written until this works |
| 4. Network | Subnet | Discovered via the API, presented as a numbered list |
| 5. Shape | Shape, OCPUs, memory, boot volume, name | Defaults to the Always Free A1 |
| 6. Image | OS and version | Looked up via the API; you pick from actual matching builds |
| 7. SSH | Public key file or pasted key | Also the image's default login user |
| 8. Notifications | Pushover, ntfy, webhook | All optional, all can be combined |
| 9. Schedule | Retry interval | Ten minutes by default |

Everything lands in `/etc/oracle-sniper/config`, which is a plain shell file you can edit afterwards. See [`config.example`](config.example) for every option with commentary.

### Getting the API key registered

In the OCI console: **Profile → My profile → API keys → Add API key → Paste a public key**. Paste the block the installer prints, then confirm. Oracle immediately shows a configuration snippet containing your user OCID, tenancy OCID and fingerprint — exactly the values step 1 asked for.

Freshly added keys occasionally need a minute before they authenticate. If step 3 fails right after registering one, wait and re-run `oracle-sniper check`.

---

## Usage

```bash
oracle-sniper status        # timer state, target instance, recent attempts
oracle-sniper run           # try once, right now
oracle-sniper check         # verify config and API access, change nothing
oracle-sniper test-notify   # send a test through every configured channel
```

Follow the hunt live:

```bash
journalctl -u oracle-sniper.service -f
```

Stop it:

```bash
sudo systemctl disable --now oracle-sniper.timer
```

---

## How it works

Each run does four things:

1. **Checks whether the instance already exists.** If it does, the timer is switched off and you get a notification. This guard is the most important line of defence in the whole program — see the warning below.
2. **Walks the availability domains.** A region with three of them gives three independent capacity pools and therefore three chances per round.
3. **Calls `launchInstance`.** `Out of host capacity` is expected and logged quietly. Anything else is reported once per distinct error, so a misconfiguration or an expired key does not sit unnoticed for weeks.
4. **On success, resolves the public IP** by polling the VNIC attachment, sends it to you and disables the timer.

### Requests are signed, not proxied

Oracle's API uses HTTP Signatures (`draft-cavage-http-signatures`). `bin/oci-api.sh` builds the signing string, signs it with your RSA key via `openssl`, and attaches the `Authorization` header. Roughly 40 lines, no dependencies, and it works identically on x86 and Arm.

### Failure handling

This is where the design earned its scars. The first version inherited `set -e` from a sourced helper, and a single dropped connection killed the run silently — mid-flight, without a log line. Oracle had already created the instance; the notification never went out; the next run only saw "instance already exists" and quietly switched the timer off. The success was invisible for two weeks.

So now:

- The helper library never enables `set -e`, and the main script explicitly disables it after sourcing.
- An `EXIT` trap reports **any** unclean termination, so a silent death is impossible.
- A connection error during `launchInstance` is not treated as failure. Oracle may have accepted the request anyway, so the run moves on and the next one detects the instance and reports it.
- The "already exists" path notifies too, precisely because it might be the first time anyone hears about it.

---

## Warnings worth reading

### Keep `STOP_WHEN_DONE=true`

With it off, the sniper keeps launching instances after the first success. Everything beyond the free allowance is billed to your card. There is no upside to turning it off.

### The console's capacity hint is unreliable

The create form happily states *"You can create Ampere A1 compute instances in any availability domain"* while every actual attempt fails. The same is true of the Compute Capacity Report, which has a [long-standing issue](https://github.com/oracle/oci-cli/issues/748) of reporting `AVAILABLE` for capacity that is not there. Only a real `launchInstance` call tells the truth — which is exactly what this tool does.

### Oracle rate-limits

Hammering the API earns you `HTTP 429`. The sniper ends a round early when it sees one, and the default interval of ten minutes stays well clear. Do not set it to 30 seconds; you will get throttled and win nothing.

### Always Free has been cut

Since **15 June 2026** the A1 allowance is **2 OCPU / 12 GB**, down from 4 / 24. It is a monthly budget — 1,500 OCPU-hours and 9,000 GB-hours — which across ~730 hours works out to those numbers running continuously. Oracle changed this without an announcement; the documentation was simply updated.

### Idle instances get reclaimed

On accounts that never upgraded to Pay-as-you-go, Oracle may reclaim instances that stay below 20% CPU, network *and* memory utilisation across a 7-day window. Winning the machine is not the same as keeping it — give it something to do.

---

## Configuration reference

Full commentary lives in [`config.example`](config.example). The options you are most likely to touch:

| Option | Purpose |
|---|---|
| `SHAPE`, `OCPUS`, `MEMORY_GB` | What to ask for. `OCPUS`/`MEMORY_GB` apply to `.Flex` shapes only |
| `AVAILABILITY_DOMAINS` | Restrict to specific ADs; empty means all of them |
| `CLOUD_INIT_FILE` | A cloud-init file applied at first boot |
| `STOP_WHEN_DONE` | Leave at `true` |
| `NOTIFY_*` | Pushover, ntfy and webhook targets |

Changing the retry interval means editing the timer:

```bash
sudo systemctl edit --full oracle-sniper.timer   # adjust OnUnitActiveSec
sudo systemctl restart oracle-sniper.timer
```

---

## Troubleshooting

**`check` reports the API call failed.** In order of likelihood: the key is not registered in the OCI profile yet, the fingerprint does not match the private key, or the region is wrong. Note that the OCIDs for user and tenancy are different values that look confusingly alike.

**Every round says "no capacity" for days.** That is the normal experience in busy regions. Regions with three availability domains give better odds than single-AD ones. Upgrading to Pay-as-you-go removes the problem entirely — Always Free resources stay free, but capacity becomes available immediately.

**The instance exists but you cannot reach it.** Two firewall layers must be open, and forgetting one costs hours: the OCI **security list** on the subnet, and **iptables inside the VM** — Oracle's Linux images ship with rules that reject everything except SSH.

**Notifications never arrive.** `oracle-sniper test-notify` exercises every configured channel and reports which one failed.

---

## Uninstall

```bash
sudo systemctl disable --now oracle-sniper.timer
sudo rm -f /usr/local/bin/oracle-sniper /etc/systemd/system/oracle-sniper.{service,timer}
sudo rm -rf /usr/local/lib/oracle-sniper /var/lib/oracle-sniper
sudo systemctl daemon-reload
```

Your credentials in `/etc/oracle-sniper/` are left alone deliberately. Remove them yourself when you are sure you are done, and revoke the API key in the OCI console.

---

## License

MIT — see [LICENSE](LICENSE).

Not affiliated with Oracle. "Oracle Cloud" is their trademark; this is an independent tool that talks to their public API.
