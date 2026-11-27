# oracle-sniper

Oracle Cloud's Always Free tier is genuinely generous — 2 Arm OCPUs with 12 GB of RAM, for free, forever. The catch is that in popular regions those machines are almost never available. You fill in the launch form, hit *Create*, and get:

```
Out of host capacity.
```

Capacity does free up, constantly, but in seconds-wide windows as other people's instances get terminated. Whoever asks at the right moment wins. That is not a job for a human refreshing a browser tab.

**oracle-sniper** asks for you. It runs on any Linux box you already own — as a systemd timer or as a container — retries across every availability domain in your region, stops itself the moment it succeeds, and tells you where your new machine is.

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

## ⏳ Bring patience

This matters more than any configuration option, so it goes first.

In the run this tool was built for, the timer started on **8 August** and the instance appeared on **22 August** — **two weeks** of "no capacity", roughly 2,000 failed attempts, in Frankfurt across all three availability domains. Reports from others range from a few hours to well over a month.

So: **set it up, then forget about it.** Do not shorten the interval because nothing happened on day three; Oracle rate-limits aggressive polling and you will only make it worse. The whole point of this tool is that waiting costs you nothing — one second of CPU time per attempt, capped at 64 MB of memory, and a notification when it finally lands.

If you want it faster, the only reliable lever is upgrading the account to Pay-as-you-go. Always Free resources stay free, but capacity becomes available immediately.

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/brightcolor/oracle-sniper/main/install.sh | sudo bash
```

The installer asks how you want to run it, checks the prerequisites for that choice, and offers to install anything missing. Run it again later to reconfigure or to remove everything.

### Two ways to run it

|  | systemd timer | Docker |
|---|---|---|
| Needs | systemd, curl, openssl | Docker with the compose plugin |
| Runs | every N minutes via timer | container loop, exits on success |
| Logs | `journalctl -u oracle-sniper` | `docker logs oracle-sniper` |

Both use the same configuration file and behave identically. Pick whatever fits the host.

If Docker is missing and you choose that mode, the installer offers to install it via the official convenience script — or to cancel, so nothing happens behind your back.

### Requirements

On a systemd host: `bash`, `curl`, `openssl`, `flock`, `base64`. Nothing you have to fetch first on any mainstream distribution — and if something is missing, the installer offers to install it through your package manager.

No Python, no OCI CLI, no SDK. Requests are signed with `openssl` directly. The whole thing is about 20 KB of shell.

---

## Create an Oracle API key

oracle-sniper talks to Oracle's API with an **API signing key**: an RSA key pair whose public half is registered with your Oracle user, while the private half stays on the machine that runs the sniper. The installer can generate the pair for you and walks you through registering it. This section covers the same steps by hand, which is the way to go for Docker or when you want to understand what the installer asks for.

### 1. Get a key pair

Pick one of the two routes.

**Route A: let the console generate it.** Easiest if you are sitting at a browser.

1. Sign in to the [OCI console](https://cloud.oracle.com/).
2. Open the profile menu (the person icon at the top right) and choose **My profile**. Some console versions call this entry **User settings**.
3. Open **API keys**. In newer console versions it sits on the **Tokens and keys** tab; older ones list it under *Resources* on the left.
4. Click **Add API key**, keep **Generate API key pair** selected, and click **Download private key**. Optionally download the public key too.
5. Click **Add**.

The download is the only copy of the private key Oracle ever gives you. Store it somewhere safe right away.

**Route B: generate it yourself.** Useful on a headless server, because the private key is created there directly.

```bash
openssl genrsa -out api_key.pem 2048
chmod 600 api_key.pem
openssl rsa -pubout -in api_key.pem -out api_key_public.pem
```

Then, in the console under **My profile** (or **User settings**) **→ API keys → Add API key**, choose **Paste a public key**, paste the contents of `api_key_public.pem` (including the `BEGIN` and `END` lines) and click **Add**.

### 2. Copy the values from the snippet

After **Add**, the console shows a *Configuration file preview*. It contains everything the sniper needs:

```
[DEFAULT]
user=ocid1.user.oc1..aaaa...
fingerprint=aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99
tenancy=ocid1.tenancy.oc1..aaaa...
region=eu-frankfurt-1
key_file=<path to your private keys file>
```

| Snippet line | oracle-sniper setting |
|---|---|
| `user` | `OCI_USER` |
| `fingerprint` | `OCI_FINGERPRINT` |
| `tenancy` | `OCI_TENANCY`, and also `OCI_COMPARTMENT` unless you use a sub-compartment |
| `region` | `OCI_REGION` |
| `key_file` | `OCI_KEY_FILE`, the path to the private key on your host |

You can open the snippet again later: the **⋮** menu next to the key in the API keys list has **View configuration file**.

### 3. Hand the private key to the sniper

- **systemd host:** run the installer and give it the path to your private key when it asks; it copies the key to `/etc/oracle-sniper/api_key.pem` with permissions `0600`. With route B you can also leave the prompt empty and let the installer generate a fresh pair, then paste the public key it prints.
- **Docker:** mount the file read-only (`-v /path/to/api_key.pem:/etc/oracle-sniper/api_key.pem:ro`) or pass it as an environment variable:

  ```bash
  base64 -w0 < api_key.pem      # value for OCI_KEY_BASE64
  ```

### 4. Check that it works

```bash
oracle-sniper check
```

A freshly added key can take a minute before Oracle accepts it. If `check` still fails after that, compare the fingerprint of your local key with the one shown in the console:

```bash
openssl rsa -pubout -outform DER -in api_key.pem | openssl md5 -c
```

The two values have to match. If they differ, the key file belongs to a different key pair.

### Good to know

- Each Oracle user can hold **three API keys**. Delete keys you no longer use in the same list.
- The private key grants full API access to your account. Keep it out of Git repositories, chat messages and screenshots, and give it permissions `0600`.
- When you retire the sniper, delete the key in the console (**⋮ → Delete**). The uninstaller reminds you of this.

---

## Docker

The image is published for **linux/amd64 and linux/arm64**, so it runs on Ampere and Graviton instances as well as ordinary x86 hosts.

```bash
docker pull ghcr.io/brightcolor/oracle-sniper:latest
```

Mount a config file, or pass everything as environment variables:

```yaml
services:
  oracle-sniper:
    image: ghcr.io/brightcolor/oracle-sniper:latest
    restart: on-failure          # NOT unless-stopped -- see below
    environment:
      CHECK_INTERVAL_SECONDS: 600
      OCI_USER: ocid1.user.oc1..aaaa...
      OCI_TENANCY: ocid1.tenancy.oc1..aaaa...
      OCI_FINGERPRINT: aa:bb:cc:...
      OCI_REGION: eu-frankfurt-1
      OCI_COMPARTMENT: ocid1.tenancy.oc1..aaaa...
      OCI_KEY_BASE64: LS0tLS1CRUdJTi...    # base64 of the private key
      INSTANCE_NAME: free-instance
      SHAPE: VM.Standard.A1.Flex
      OCPUS: 2
      MEMORY_GB: 12
      IMAGE_ID: ocid1.image.oc1...
      SUBNET_ID: ocid1.subnet.oc1...
      SSH_PUBLIC_KEY: "ssh-ed25519 AAAA... you@example.com"
      NOTIFY_PUSHOVER_TOKEN: ...
      NOTIFY_PUSHOVER_USER: ...
    volumes:
      - sniper-state:/var/lib/oracle-sniper
    mem_limit: 64m

volumes:
  sniper-state:
```

**Use `restart: on-failure`, not `unless-stopped`.** When the sniper wins, the container exits with code 0 on purpose. A restart-always policy would bring it straight back up, and it would spend the rest of its life re-discovering that the instance already exists.

The state volume matters for the same reason: it holds the marker that says "already won". Without it, a recreated container starts hunting again.

---

## Uninstall

Run the installer again and pick *Uninstall*. It removes the program, the systemd units and the container, and then asks separately whether your **configuration, API key and state** should go too — because keeping them lets you reinstall later without redoing the setup.

Your Oracle Cloud instance is never touched. If you delete the credentials, the installer reminds you to revoke the API key in the OCI console.

---

## Usage

```bash
oracle-sniper status        # timer state, target instance, recent attempts
oracle-sniper run           # try once, right now
oracle-sniper pause         # stop hunting, survives restarts
oracle-sniper resume        # carry on
oracle-sniper check         # verify config and API access, change nothing
oracle-sniper test-notify   # send a test through every configured channel
```

In Docker, pass the same words to the container: `docker run ... oracle-sniper check`.

### The two brake files

Both live in the state directory — `/var/lib/oracle-sniper`, the mounted volume in Docker — so they survive a restart, a recreated container and a rebuilt image:

| File | Written by | Meaning |
|---|---|---|
| `done` | the sniper itself, on success | An instance was acquired. Stop, permanently. |
| `paused` | you, via `oracle-sniper pause` | Stop for now. |

Either one makes a run exit immediately. In the container they are checked at startup **and before every round**, so pausing takes effect without a restart. Deleting the file is all it takes to continue — `resume` does exactly that, and warns you if `done` is still in the way.

This is why the state volume matters. Drop it (`docker compose down -v`) and the sniper forgets that it already won — then starts hunting for a second instance, which Oracle bills.

---

## How it works

Each run does four things:

1. **Checks whether the instance already exists.** If it does, everything stops and you get a notification. This guard is the most important line of defence in the whole program — see the warning below.
2. **Walks the availability domains.** A region with three of them gives three independent capacity pools and therefore three chances per round.
3. **Calls `launchInstance`.** `Out of host capacity` is expected and logged quietly. Anything else is reported once per distinct error, so a misconfiguration or an expired key does not sit unnoticed for weeks.
4. **On success, resolves the public IP**, sends it to you, and stops — by disabling the timer, or by exiting the container.

### Requests are signed, not proxied

Oracle's API uses HTTP Signatures (`draft-cavage-http-signatures`). `bin/oci-api.sh` builds the signing string, signs it with your RSA key via `openssl`, and attaches the `Authorization` header. Roughly 40 lines, no dependencies, identical on x86 and Arm.

### Failure handling

This is where the design earned its scars. The first version inherited `set -e` from a sourced helper, and a single dropped connection killed the run silently — mid-flight, without a log line. Oracle had already created the instance; the notification never went out; the next run only saw "instance already exists" and quietly stopped. The success was invisible for two weeks.

So now:

- The helper library never enables `set -e`, and the main script explicitly disables it after sourcing.
- An `EXIT` trap reports **any** unclean termination, so a silent death is impossible.
- A connection error during `launchInstance` is not treated as failure. Oracle may have accepted the request anyway, so the run moves on and the next one detects the instance and reports it.
- The "already exists" path notifies too, precisely because it might be the first time anyone hears about it.

A second scar: Oracle answers compactly on some services and pretty-printed on others (`"key":"value"` versus `"key" : "value"`). Matching only the compact form returned nothing at all on the padded services — with no error, so it looked like the field was simply absent. The parser now accepts both.

A third, found while testing the container image: the "does the instance already exist" check used `grep '\(RUNNING\|PROVISIONING\)'`. That is GNU grep syntax. Alpine ships **busybox grep**, which does not support `\|` alternation in basic expressions — so inside the container the pattern never matched. The sniper would have concluded that no instance existed and launched a **second one** next to the one it already owned, which Oracle bills. Every pattern now uses `grep -E`. If you package this for another minimal base image, keep that in mind.

---

## Warnings worth reading

### Keep `STOP_WHEN_DONE=true`

With it off, the sniper keeps launching instances after the first success. Everything beyond the free allowance is billed to your card. There is no upside to turning it off.

### The console's capacity hint is unreliable

The create form happily states *"You can create Ampere A1 compute instances in any availability domain"* while every actual attempt fails. The same is true of the Compute Capacity Report, which has a [long-standing issue](https://github.com/oracle/oci-cli/issues/748) of reporting `AVAILABLE` for capacity that is not there. Only a real `launchInstance` call tells the truth — which is exactly what this tool does.

### Oracle rate-limits

Hammering the API earns you `HTTP 429`. The sniper ends a round early when it sees one, and the default interval of ten minutes stays well clear.

### Always Free has been cut

Since **15 June 2026** the A1 allowance is **2 OCPU / 12 GB**, down from 4 / 24. It is a monthly budget — 1,500 OCPU-hours and 9,000 GB-hours — which across ~730 hours works out to those numbers running continuously. Oracle changed this without an announcement; the documentation was simply updated.

### Idle instances get reclaimed

On accounts that never upgraded to Pay-as-you-go, Oracle may reclaim instances that stay below 20% CPU, network *and* memory utilisation across a 7-day window. Winning the machine is not the same as keeping it.

### Hold the matching private key

The installer takes a public key and installs it on the instance. Make sure you actually have the private half — an instance you cannot log into has to be rebuilt, and rebuilding means winning the capacity lottery all over again.

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

---

## Troubleshooting

**`check` reports the API call failed.** In order of likelihood: the key is not registered in the OCI profile yet, the fingerprint does not match the private key, or the region is wrong. Note that the OCIDs for user and tenancy are different values that look confusingly alike.

**Every round says "no capacity" for days.** That is normal — see the patience section at the top.

**The instance exists but you cannot reach it.** Two firewall layers must be open, and forgetting one costs hours: the OCI **security list** on the subnet, and **iptables inside the VM** — Oracle's Linux images ship with rules that reject everything except SSH.

**The container keeps restarting after success.** Your restart policy is `always` or `unless-stopped`. Use `on-failure`.

**Notifications never arrive.** `oracle-sniper test-notify` exercises every configured channel and reports which one failed.

---

## License

MIT — see [LICENSE](LICENSE).

Not affiliated with Oracle. "Oracle Cloud" is their trademark; this is an independent tool that talks to their public API.
