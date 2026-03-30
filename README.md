
# Dependency Cooldowns

In March 2026 alone, three widely-used packages were compromised after attackers gained access to tokens used to publish
those packages to their respective package registries.
[LiteLLM](https://www.herodevs.com/blog-posts/the-litellm-supply-chain-attack-what-happened-why-it-matters-and-what-to-do-next)
had versions on PyPI that harvested cloud credentials, SSH keys, and
Kubernetes configs for about two hours before removal.
The [Telnyx Python SDK](https://socket.dev/blog/telnyx-python-sdk-compromised) shipped platform-specific backdoors
triggered at import time, bypassing install-time detection entirely.
And [axios](https://www.stepsecurity.io/blog/axios-compromised-on-npm-malicious-versions-drop-remote-access-trojan),
with over 100 million weekly npm downloads, had versions that dropped a remote access trojan via an injected
dependency, live for 2–3 hours before npm pulled them.

Anyone who ran `pip install` or `npm install` while the malicious packages were available could have infected their
system and potentially exposed sensitive data to the attackers. That's the inherent risk of always resolving to the
latest version of a package at install time. Dependency cooldowns are a relatively simple fix to prevent this from
happening: tell your package manager to ignore any version that hasn't existed for at least N days. Security
researchers and automated scanners catch most compromised packages within hours or days of publication. A cooldown just
makes sure you're not the one who installs it before they do.

## Does it actually work?

[An analysis of ten prominent supply chain attacks](https://blog.yossarian.net/2025/11/21/We-should-all-be-using-dependency-cooldowns)
found that eight had exploitation windows under one week. All but one lasted under two weeks. Attackers move fast
after compromising a project, but they also get caught fast. A three-day cooldown would have blocked most of these. In
the August 2025 Nx npm attack, malicious code exfiltrated credentials within a 4–5 hour window before the package
was pulled. The LiteLLM compromise mentioned above also had a window of only a few hours (first detected at 10:39 UTC,
quarantined on PyPI at 13:38 UTC).

That's roughly an 80-90% reduction in exposure for a simple config change (if the package manager of your choice
supports the cooldown feature, see below). All native implementations enforce cooldowns on transitive dependencies too,
not just the packages you directly install.

All examples below use a three-day cooldown. Pick whatever number you're comfortable with; even one day makes a real
difference.

## Python Ecosystem

### uv

[uv](https://docs.astral.sh/uv/) introduced the built-in cooldown feature in version 0.9.17. It uses relative durations
natively and supports several timestamp and duration formats. For example, the following installation command of package
`foo` will ignore any versions of this package that are newer than three days:

```bash
uv pip install --exclude-newer '3 days' foo
```

To make this applicable to all `uv` commands that install packages, add the following to your `~/.config/uv/uv.toml`:

```toml
exclude-newer = "3 days"
```

Or as an environment variable:

```bash
export UV_EXCLUDE_NEWER="3 days"
```

For project-level config in `pyproject.toml`:

```toml
[tool.uv]
exclude-newer = "3 days"
```

uv also supports per-package overrides via `exclude-newer-package` if you need to exempt specific packages.

Refer to [uv documentation](https://docs.astral.sh/uv/reference/settings/#exclude-newer) for more information about this
configuration setting.

### pip

pip 26.0 added `--uploaded-prior-to`, but unfortunately it only takes absolute timestamps, not relative durations like
"3 days ago". [pip issue #13674](https://github.com/pypa/pip/issues/13674) tracks the implementation of relative
durations.

To work around this limitation, you can for example compute the cutoff date on the fly every time you run
pip by adding this function to your `~/.bashrc` (or a shell RC file of your choice):

```bash
pip() {
    local pip_major
    pip_major=$(command pip --version 2>/dev/null | grep -oP '\d+(?=\.\d+)' | head -1)

    case "$1" in
        install|download|wheel)
            if [[ "${pip_major:-0}" -ge 26 ]]; then
                local cutoff
                cutoff=$(date -u -d '3 days ago' '+%Y-%m-%dT%H:%M:%SZ')
                command pip "$1" --uploaded-prior-to "$cutoff" "${@:2}"
            else
                echo "warning: pip ${pip_major:-unknown} does not support --uploaded-prior-to (need >= 26), skipping cooldown" >&2
                command pip "$@"
            fi
            ;;
        *)
            command pip "$@"
            ;;
    esac
}
```

Alternatively, you can set an absolute date in `~/.config/pip/pip.conf` and update it automatically with a cron job
(see Seth Larson's [blog post](https://sethmlarson.dev/pip-relative-dependency-cooling-with-crontab) covering this
approach).

`~/.config/pip/pip.conf`:

```ini
[install]
uploaded-prior-to = 2026-03-27
```

`/usr/local/bin/pip-dependency-cooldown`:

```python
#!/usr/bin/python3
import datetime, sys, os, re


def main() -> int:
    pip_conf = os.path.abspath(os.path.expanduser(sys.argv[1]))
    days = int(sys.argv[2])

    with open(pip_conf, "r") as f:
        pip_conf_data = f.read()

    uploaded_prior_to_re = re.compile(
        r"^uploaded-prior-to\s*=\s*2[0-9]{3}-[0-9]{2}-[0-9]{2}$", re.MULTILINE
    )

    new_date = (datetime.date.today() - datetime.timedelta(days=days)).strftime("%Y-%m-%d")
    pip_conf_data = uploaded_prior_to_re.sub(f"uploaded-prior-to = {new_date}", pip_conf_data)

    with open(pip_conf, "w") as f:
        f.write(pip_conf_data)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

Hourly cronjob:

```
0 * * * * /usr/local/bin/pip-dependency-cooldown ~/.config/pip/pip.conf 3 2>&1 | logger -t pip-dependency-cooldown
```

For containers or ephemeral environments, you can also use the following environment variable:

```bash
export PIP_UPLOADED_PRIOR_TO="2026-03-27"
```

See [pip documentation](https://pip.pypa.io/en/stable/cli/pip_install/#cmdoption-uploaded-prior-to) for more information
about this configuration option.

### conda

The conda package manager does not have a native cooldown feature, but
issue [#15759](https://github.com/conda/conda/issues/15759) proposed its implementation.

## JavaScript Ecosystem

### npm

npm added the `min-release-age` cooldown option in version 11.10.0. To set it globally, execute:

```bash
npm config set min-release-age=3 # days
```

Or set the following in your project's `.npmrc`:

```ini
min-release-age = 3 # days
```

`npm` chose to use a unit that represents the number of days that a release must be
available before it will be considered for installation. In true JavaScript fashion, the other JS package managers chose
completely different units of time. Unlike pnpm and Yarn (see below), npm doesn't yet have a way to
exempt specific packages from the cooldown.
See [npm documentation](https://docs.npmjs.com/cli/v11/using-npm/config#min-release-age) for more information.

### pnpm (JavaScript/Node.js)

pnpm 10.16.0 added `minimumReleaseAge` to support cooldowns; you can add the following to your `~/.config/pnpm/rc` file
(or the equivalent project-specific configuration file):

```text
minimumReleaseAge: 4320 # 3 days
```

The value represents the number of minutes a release must be available before it is installed. You can also exclude
specific packages from this policy with:

```text
minimumReleaseAge: 4320 # 3 days
minimumReleaseAgeExclude:
- webpack
- react
```

See [pnpm documentation](https://pnpm.io/settings#minimumreleaseage) for more information.

### Yarn (JavaScript/Node.js)

Yarn added support for cooldowns via the `npmMinimalAgeGate` configuration option in version 4.10.0; in your
`.yarnrc.yml` file, add:

```yaml
npmMinimalAgeGate: "3d"
```

To exempt trusted packages:

```yaml
npmMinimalAgeGate: "3d"
npmPreapprovedPackages:
  - typescript
  - eslint
```

More information can be found in [yarn documentation](https://yarnpkg.com/configuration/yarnrc#npmMinimalAgeGate).

### Bun (JavaScript/Node.js)

Bun supports cooldowns with the `minimumReleaseAge` configuration option in `bunfig.toml`, first introduced in version
1.3. This time the value is specified in seconds:

```toml
[install]
minimumReleaseAge = 259200 # 3 days
```

For more information, see [bun documentation](https://bun.com/docs/pm/cli/install#minimum-release-age).

### Deno (JavaScript/TypeScript)

Deno added support for cooldowns in version 2.6. The age can be specified as a number of minutes, an ISO 8601
duration (e.g. `P3D` for three days), or an RFC 3339 absolute timestamp. In your `deno.json` file, you can configure
it with:

```json
{
  "minimumDependencyAge": "P3D"
}
```

Or use the `--minimum-dependency-age` flag:

```bash
deno install --minimum-dependency-age=P3D
deno update --minimum-dependency-age=P3D
deno outdated --minimum-dependency-age=P3D
```

See [deno documentation](https://docs.deno.com/runtime/reference/cli/install/#options-minimum-dependency-age) for more
information.

## Cargo (Rust)

Cargo doesn't have native cooldown support yet. Cargo 1.94 added `pubtime` fields to the crate index (the prerequisite),
and an RFC ([#3923](https://github.com/rust-lang/rfcs/pull/3923)) for native cooldowns is in progress.

Until that is implemented, the third-party [`cargo-cooldown`](https://crates.io/crates/cargo-cooldown) crate can be used
instead:

```bash
cargo install cargo-cooldown
COOLDOWN_MINUTES=4320 cargo cooldown build  # 3 days
```

## Other ecosystems

These language ecosystems currently offer no native cooldown support. There's
an [open proposal](https://github.com/golang/go/issues/76485) for Go, but it hasn't
been accepted. [NuGet](https://github.com/NuGet/Home/issues/14657),
[Composer](https://github.com/composer/composer/issues/12552), and
[Hex](https://github.com/hexpm/hex/issues/1113) also have open feature requests. Your best bet is
locking your dependencies to exact versions, and configuring cooldowns in Dependabot or Renovate for automated updates
(see below).

Maven/Gradle (Java), RubyGems/Bundler (Ruby), and Swift Package Manager don't have native cooldowns either, and no
open requests exist requesting this feature as of today.

One exception worth noting: the community-run [gem.coop package index](https://gem.coop), an alternative to RubyGems,
enforces a 48-hour delay on newly published gems at the registry level.

## Dependency update bots

If you rely on automated dependency updates, you can configure cooldowns in their configurations as well. Renovate has
supported dependency cooldowns the longest; its `minimumReleaseAge` (formerly `stabilityDays`) has been supported for
years. Renovate 42 even made a 3-day minimum the default for npm via the `config:best-practices` preset.

To configure a cooldown of three days in your `renovate.json` file, use:

```json
{
  "packageRules": [
    {
      "matchUpdateTypes": [
        "major",
        "minor",
        "patch"
      ],
      "minimumReleaseAge": "3 days"
    }
  ]
}
```

Dependabot also has a cooldown feature that can be specified in `dependabot.yml`:

```yaml
version: 2
updates:
  - package-ecosystem: pip
    directory: /
    schedule:
      interval: daily
    cooldown:
      default-days: 3
      semver-major-days: 7
      semver-minor-days: 3
      semver-patch-days: 3
```

Dependabot does exempt security updates from cooldowns, so critical CVE fixes still get PRs immediately.

## Container images

The configurations above work fine in your developer setups, but if you're building container images for development,
those settings don't carry over automatically. If your team maintains shared base images for development, bake the
cooldown configs into those images so that individual developers don't have to remember to configure these settings
themselves.

### Relative durations

uv, npm, pnpm, Bun, Deno, and Yarn all accept relative durations, so you can just set environment variables or add
config files into the image at build time. These don't go stale because the duration is always relative to "now".

In a `Containerfile`:

```dockerfile
FROM quay.io/fedora/fedora

# uv cooldown
ENV UV_EXCLUDE_NEWER="3 days"

# npm cooldown (if you also use Node)
COPY .npmrc /path/to/your/app/dir
```

Every `uv sync`/`uv pip install` or `npm install` inside the container respects the cooldown with no extra work.

### pip

Since pip only takes absolute dates, compute the cutoff at build time in the same `RUN` step that installs your
dependencies:

```dockerfile
FROM quay.io/fedora/fedora

COPY requirements.txt .
RUN PIP_UPLOADED_PRIOR_TO=$(date -u -d '3 days ago' '+%Y-%m-%dT%H:%M:%SZ') \
    pip install -r requirements.txt
```

The date is evaluated when the image is built, which is exactly when `pip install` runs.

If you maintain development containers where developers might run `pip install` interactively, you'll also want the
cooldown to apply at runtime. You can replicate the same shell function wrapper from the earlier section into
`/etc/profile.d/` so it's sourced for all interactive shells:

```dockerfile
COPY pip-cooldown.sh /etc/profile.d/pip-cooldown.sh
```

## cooldowns.sh

The [`cooldowns.sh`](https://github.com/mprpic/cooldowns/blob/main/cooldowns.sh) script is a small helper that
configures cooldowns across multiple package managers in a single command and can verify that everything is set up
correctly. It supports pip, uv, npm, pnpm, Yarn, Bun, Deno, and Cargo.

### Setting cooldowns

```bash
cooldowns.sh set pip 3d
cooldowns.sh set uv "3 days"
cooldowns.sh set npm 7d
```

Each `set` command writes a user-wide configuration for that tool. Project-level configs are not modified. The exact
location depends on the tool:

| Tool  | Method            | Location                                          |
|-------|-------------------|---------------------------------------------------|
| pip   | Shell wrapper     | `/etc/profile.d/cooldowns.sh` (or `~/.bashrc`)    |
| uv    | Env var export    | `/etc/profile.d/cooldowns.sh` (or `~/.bashrc`)    |
| npm   | `.npmrc` key      | `~/.npmrc`                                        |
| pnpm  | `.npmrc` key      | `~/.npmrc`                                        |
| yarn  | Env var export    | `/etc/profile.d/cooldowns.sh` (or `~/.bashrc`)    |
| bun   | `bunfig.toml` key | `~/.bunfig.toml`                                  |
| deno  | Shell aliases     | `/etc/profile.d/cooldowns.sh` (or `~/.bashrc`)    |
| cargo | Env var export    | `/etc/profile.d/cooldowns.sh` (or `~/.bashrc`)    |

Tools that use profile scripts write to `/etc/profile.d/cooldowns.sh` if the directory exists and is writable,
otherwise they fall back to `~/.bashrc`.

### Checking cooldowns

```bash
cooldowns.sh check
```

The `check` command scans all installed package managers and reports their cooldown status:

```
Checking dependency cooldown configurations...

  ok      pip      shell wrapper with 3-day cooldown in /etc/profile.d/cooldowns.sh
  ok      uv       UV_EXCLUDE_NEWER="3 days" in /etc/profile.d/cooldowns.sh
  ok      npm      min-release-age=3d in /home/user/.npmrc
  MISS    cargo    no cooldown configured

3 configured, 0 warnings, 1 not configured
```

It exits non-zero if any tool is missing a cooldown or has a stale configuration, making it useful as a CI gate.

### Usage in containers

The script can also be used in `Containerfile`/`Dockerfile` builds. Copy it into the image and run `set` commands
during the build:

```dockerfile
FROM quay.io/fedora/fedora

COPY cooldowns.sh /usr/local/bin/
RUN cooldowns.sh set pip 3d && cooldowns.sh set uv 3d && cooldowns.sh set npm 3d
```

You can also add a `check` step to verify everything is configured:

```dockerfile
RUN cooldowns.sh check
```

## Quick reference

| Package Manager | Cooldown support    | Configuration                                              |
|-----------------|---------------------|------------------------------------------------------------|
| pip             | Absolute dates only | `--uploaded-prior-to` / shell wrapper / cron               |
| uv              | Relative durations  | `exclude-newer = "3 days"` in `uv.toml` / `pyproject.toml` |
| npm             | Relative durations  | `min-release-age=3` in `.npmrc`                            |
| pnpm            | Relative durations  | `minimumReleaseAge: 4320` in `pnpm-workspace.yaml`         |
| Yarn            | Relative durations  | `npmMinimalAgeGate: "3d"` in `.yarnrc.yml`                 |
| Bun             | Relative durations  | `minimumReleaseAge = 259200` in `bunfig.toml`              |
| Deno            | Relative durations  | `minimumDependencyAge: "P3D"` in `deno.json`               |
| Cargo           | Third-party only    | `cargo-cooldown` crate                                     |
| Go              | Not available       | Dependabot/Renovate only                                   |
| Maven/Gradle    | Not available       | Dependabot/Renovate only                                   |
| NuGet           | Not available       | Dependabot/Renovate only                                   |
| Composer        | Not available       | Dependabot/Renovate only                                   |
| RubyGems        | Not available       | gem.coop proxy / Dependabot/Renovate                       |

## Conclusion

It is worth noting that cooldowns don't protect against typosquatting, long-term maintainer compromise (like xz-utils),
or zero-day vulnerabilities in packages you already have installed. And an aggressive cooldown can delay legitimate
security patches, so pair cooldowns with active vulnerability alerting (`pip-audit`, `npm audit`, Dependabot security
updates) to make sure critical fixes still reach you quickly.

That said, most real-world package compromises follow the same pattern: an attacker publishes a malicious version, and
it gets caught and pulled within hours or days. A three-day cooldown would have blocked the majority of recent incidents
with zero ongoing effort after initial setup. Pick a number, configure it, and stay safe out there!
