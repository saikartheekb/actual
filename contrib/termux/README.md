# Actual Budget on Termux

This folder contains an Android-first setup for running Actual Budget inside Termux and using the Android browser as the app UI.

## What it installs

`termux-setup.sh` installs the Actual sync server, the Actual CLI, Termux services, a watchdog, and SMS transaction review tools.

After setup, Actual runs at:

```sh
http://127.0.0.1:5006
```

Open that URL in Chrome or Firefox on Android and add it to the home screen for PWA-style use.

## Install

Install Termux from F-Droid or GitHub, then run:

```sh
sh contrib/termux/termux-setup.sh
```

Disable Android battery optimization for Termux so the service is not killed in the background.

## Configure the CLI

Copy the generated example environment file and fill in your server and budget values:

```sh
cp ~/actual-tools/actual-env.example ~/actual-tools/actual-env
. ~/actual-tools/actual-env
```

Useful discovery commands:

```sh
actual budgets list
actual accounts list
```

The SMS review flow requires:

```sh
export ACTUAL_SERVER_URL=http://127.0.0.1:5006
export ACTUAL_PASSWORD='your-server-password'
export ACTUAL_SYNC_ID='your-budget-sync-id'
```

Optionally set a default account for SMS imports:

```sh
export ACTUAL_SMS_ACCOUNT_ID='your-account-id'
```

## Review SMS spends before importing

Install the Termux:API Android app, grant SMS permission, then preview what the parser sees:

```sh
node ~/actual-tools/sms-review.mjs --dry-run
```

Run the interactive review queue:

```sh
node ~/actual-tools/sms-review.mjs
```

For each candidate spend or credit, the tool shows the parsed date, amount, payee, sender, raw SMS, and default Actual account. You can then:

- approve: import it
- edit: change date, amount, payee, or notes
- account: choose a different Actual account
- decline: hide this SMS from future review
- skip: leave it for a later review
- quit: stop after importing already approved items

The review state is saved at:

```sh
~/actual-tools/sms-review-state.json
```

Declined and imported SMS fingerprints are remembered so the same message is not repeatedly offered.

## Non-interactive import

The older command name is still present as a wrapper for automation:

```sh
node ~/actual-tools/sms-to-actual.mjs
```

It imports all new parsed SMS transactions into `ACTUAL_SMS_ACCOUNT_ID`. Use the interactive review command for normal daily use.

## Service commands

```sh
sv status actual-budget
sv status actual-watchdog
svlogtail actual-budget
svlogtail actual-watchdog
sv restart actual-budget
```