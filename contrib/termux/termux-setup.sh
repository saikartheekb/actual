#!/data/data/com.termux/files/usr/bin/sh
set -eu

APP_PORT="${ACTUAL_PORT:-5006}"
APP_HOST="${ACTUAL_HOSTNAME:-127.0.0.1}"
DATA_DIR="${ACTUAL_DATA_DIR:-$HOME/actual-data}"
TOOLS_DIR="$HOME/actual-tools"
SERVICE_DIR="$PREFIX/var/service"

echo "Actual Budget Termux setup"
echo "Server URL: http://$APP_HOST:$APP_PORT"
echo "Data dir: $DATA_DIR"

echo "Installing Termux packages..."
pkg update
pkg install -y nodejs git python make clang pkg-config sqlite openssl curl termux-api termux-services

echo "Configuring npm for Android native modules..."
npm config set build_from_source true
npm config set jobs 2

echo "Installing Actual server and CLI..."
npm install -g @actual-app/sync-server @actual-app/cli

mkdir -p "$DATA_DIR" "$TOOLS_DIR" "$HOME/actual-logs" "$HOME/actual-watchdog-logs"
mkdir -p "$SERVICE_DIR/actual-budget/log" "$SERVICE_DIR/actual-watchdog/log"

cat > "$TOOLS_DIR/run-actual.sh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
set -eu

termux-wake-lock || true

export ACTUAL_HOSTNAME="${ACTUAL_HOSTNAME:-127.0.0.1}"
export ACTUAL_PORT="${ACTUAL_PORT:-5006}"
export ACTUAL_DATA_DIR="${ACTUAL_DATA_DIR:-$HOME/actual-data}"
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=384}"

mkdir -p "$ACTUAL_DATA_DIR"
echo "Actual Budget: http://$ACTUAL_HOSTNAME:$ACTUAL_PORT"
exec actual-server
EOF

cat > "$TOOLS_DIR/watchdog.sh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
set -eu

ACTUAL_HOST="${ACTUAL_HOSTNAME:-127.0.0.1}"
ACTUAL_PORT="${ACTUAL_PORT:-5006}"
HEALTH_URL="${ACTUAL_HEALTH_URL:-http://$ACTUAL_HOST:$ACTUAL_PORT/health}"
INTERVAL_SECONDS="${ACTUAL_WATCHDOG_INTERVAL_SECONDS:-300}"

echo "Actual watchdog polling $HEALTH_URL every $INTERVAL_SECONDS seconds"

while true; do
  termux-wake-lock || true

  if curl --silent --show-error --fail --max-time 10 "$HEALTH_URL" >/dev/null; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') healthy"
  else
    echo "$(date '+%Y-%m-%d %H:%M:%S') unhealthy; restarting actual-budget"
    sv restart actual-budget || true
  fi

  sleep "$INTERVAL_SECONDS"
done
EOF

cat > "$TOOLS_DIR/sms-review.mjs" <<'EOF'
#!/usr/bin/env node
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { createInterface } from 'node:readline/promises';
import { stdin as input, stdout as output } from 'node:process';
import { spawnSync } from 'node:child_process';

const args = new Set(process.argv.slice(2));
const limitArg = process.argv.find(arg => arg.startsWith('--limit='));
const limit = Number(limitArg?.split('=')[1] ?? process.env.SMS_LIMIT ?? 200);
const statePath = process.env.ACTUAL_SMS_REVIEW_STATE ?? `${process.env.HOME}/actual-tools/sms-review-state.json`;
const defaultAccountId = process.env.ACTUAL_SMS_ACCOUNT_ID;
const nonInteractive = args.has('--auto-import');
const previewOnly = args.has('--dry-run');

function fail(message) {
  console.error(message);
  process.exit(1);
}

function run(command, commandArgs, options = {}) {
  const result = spawnSync(command, commandArgs, {
    encoding: 'utf8',
    ...options,
  });
  if (result.error) fail(`${command}: ${result.error.message}`);
  if (result.status !== 0) {
    fail(`${command} failed:\n${result.stderr || result.stdout}`);
  }
  return result.stdout;
}

function runActual(commandArgs, options = {}) {
  return run('actual', ['--format', 'json', ...commandArgs], options);
}

function loadState() {
  if (!existsSync(statePath)) return { declined: {}, imported: {} };
  try {
    const state = JSON.parse(readFileSync(statePath, 'utf8'));
    return {
      declined: state.declined && typeof state.declined === 'object' ? state.declined : {},
      imported: state.imported && typeof state.imported === 'object' ? state.imported : {},
    };
  } catch {
    return { declined: {}, imported: {} };
  }
}

function saveState(state) {
  writeFileSync(statePath, `${JSON.stringify(state, null, 2)}\n`);
}

function parseAmount(text) {
  const patterns = [
    /(?:INR|Rs\.?|Rs|\u20B9)\s*([0-9,]+(?:\.[0-9]{1,2})?)/i,
    /([0-9,]+(?:\.[0-9]{1,2})?)\s*(?:INR|Rs\.?|Rs|\u20B9)/i,
  ];
  for (const pattern of patterns) {
    const match = text.match(pattern);
    if (!match) continue;
    const value = Number(match[1].replace(/,/g, ''));
    if (Number.isFinite(value) && value > 0) return Math.round(value * 100);
  }
  return null;
}

function isCredit(text) {
  return /\b(credited|credit|deposited|received|refund|cashback|reversal)\b/i.test(text);
}

function isDebit(text) {
  return /\b(debited|debit|spent|withdrawn|paid|purchase|txn|transaction|sent|upi|used|deducted)\b/i.test(text);
}

function parsePayee(text, sender) {
  const match = text.match(/\b(?:to|at|for|towards|via)\s+([A-Z0-9 ._&@/-]{3,48})\b/i);
  if (match) return match[1].replace(/\s+/g, ' ').trim();
  const upi = text.match(/\b([A-Z0-9._-]+@[A-Z0-9._-]+)\b/i);
  if (upi) return upi[1];
  return sender || 'SMS transaction';
}

function toDate(timestamp) {
  const date = new Date(Number(timestamp));
  if (Number.isNaN(date.getTime())) return new Date().toISOString().slice(0, 10);
  return date.toISOString().slice(0, 10);
}

function fingerprint(sender, timestamp, body) {
  return createHash('sha256')
    .update([sender, timestamp, body].join('\n'))
    .digest('hex')
    .slice(0, 32);
}

function parseSms(sms) {
  const body = String(sms.body ?? sms.message ?? '');
  const amount = parseAmount(body);
  if (!amount) return null;

  let signedAmount = null;
  if (isCredit(body)) signedAmount = amount;
  if (isDebit(body)) signedAmount = -amount;
  if (signedAmount === null) return null;

  const sender = String(sms.address ?? sms.number ?? '').trim();
  const timestamp = sms.received ?? sms.date ?? sms.time ?? Date.now();
  const id = fingerprint(sender, timestamp, body);

  return {
    id,
    sender,
    sourceText: body,
    transaction: {
      date: toDate(timestamp),
      amount: signedAmount,
      payee_name: parsePayee(body, sender),
      notes: `Imported from SMS sender ${sender}: ${body}`.slice(0, 500),
      imported_id: `termux-sms-${id}`,
    },
  };
}

function formatAmount(cents) {
  const sign = cents < 0 ? '-' : '';
  return `${sign}${(Math.abs(cents) / 100).toFixed(2)}`;
}

function readSmsCandidates(state) {
  const raw = run('termux-sms-list', ['-l', String(limit), '-t', 'inbox']);
  let messages;
  try {
    messages = JSON.parse(raw);
  } catch {
    fail('Could not parse termux-sms-list output. Install Termux:API and grant SMS permission.');
  }

  return messages
    .map(parseSms)
    .filter(Boolean)
    .filter(candidate => !state.declined[candidate.id] && !state.imported[candidate.id]);
}

function readAccounts() {
  const raw = runActual(['accounts', 'list']);
  try {
    const accounts = JSON.parse(raw);
    if (!Array.isArray(accounts)) fail('Unexpected accounts list output.');
    return accounts.filter(account => !account.closed);
  } catch {
    fail('Could not parse Actual accounts. Check ACTUAL_SERVER_URL, ACTUAL_PASSWORD, and ACTUAL_SYNC_ID.');
  }
}

function accountLabel(account, index) {
  const kind = account.offbudget ? 'off budget' : 'for budget';
  return `${index + 1}. ${account.name} (${kind}, balance ${formatAmount(account.balance ?? 0)})`;
}

function pickDefaultAccount(accounts) {
  if (defaultAccountId) {
    const match = accounts.find(account => account.id === defaultAccountId);
    if (match) return match;
    console.log(`Configured ACTUAL_SMS_ACCOUNT_ID was not found: ${defaultAccountId}`);
  }
  return accounts[0];
}

async function promptForAccount(rl, accounts, currentAccount) {
  console.log('\nAccounts:');
  accounts.forEach((account, index) => console.log(`  ${accountLabel(account, index)}`));
  const answer = await rl.question(`Account [${currentAccount.name}]: `);
  if (!answer.trim()) return currentAccount;
  const index = Number(answer.trim()) - 1;
  if (!Number.isInteger(index) || index < 0 || index >= accounts.length) {
    console.log('Invalid account number; keeping current account.');
    return currentAccount;
  }
  return accounts[index];
}

async function editTransaction(rl, candidate) {
  const tx = { ...candidate.transaction };
  const date = await rl.question(`Date [${tx.date}]: `);
  if (date.trim()) tx.date = date.trim();

  const amount = await rl.question(`Amount rupees, debit negative [${formatAmount(tx.amount)}]: `);
  if (amount.trim()) {
    const parsed = Number(amount.trim());
    if (Number.isFinite(parsed)) tx.amount = Math.round(parsed * 100);
    else console.log('Invalid amount; keeping original amount.');
  }

  const payee = await rl.question(`Payee [${tx.payee_name}]: `);
  if (payee.trim()) tx.payee_name = payee.trim();

  const notes = await rl.question('Notes [keep original]: ');
  if (notes.trim()) tx.notes = notes.trim();

  candidate.transaction = tx;
}

function importTransactions(accountId, transactions) {
  runActual(['transactions', 'import', '--account', accountId, '--file', '-'], {
    input: JSON.stringify(transactions),
    stdio: ['pipe', 'inherit', 'inherit'],
  });
}

async function reviewCandidates(candidates, accounts, state) {
  const grouped = new Map();
  const defaultAccount = pickDefaultAccount(accounts);
  const rl = createInterface({ input, output });

  try {
    for (const [index, candidate] of candidates.entries()) {
      let account = defaultAccount;
      console.log('\n----------------------------------------');
      console.log(`Candidate ${index + 1}/${candidates.length}`);
      console.log(`Date:   ${candidate.transaction.date}`);
      console.log(`Amount: ${formatAmount(candidate.transaction.amount)}`);
      console.log(`Payee:  ${candidate.transaction.payee_name}`);
      console.log(`From:   ${candidate.sender}`);
      console.log(`SMS:    ${candidate.sourceText}`);
      console.log(`Account: ${account.name}`);

      while (true) {
        const action = (await rl.question('Approve, edit, account, decline, skip, quit? [a/e/c/d/s/q]: '))
          .trim()
          .toLowerCase();
        if (action === '' || action === 'a' || action === 'approve') {
          const txs = grouped.get(account.id) ?? [];
          txs.push(candidate.transaction);
          grouped.set(account.id, txs);
          state.imported[candidate.id] = { at: new Date().toISOString(), accountId: account.id };
          break;
        }
        if (action === 'e' || action === 'edit') {
          await editTransaction(rl, candidate);
          continue;
        }
        if (action === 'c' || action === 'account') {
          account = await promptForAccount(rl, accounts, account);
          continue;
        }
        if (action === 'd' || action === 'decline') {
          state.declined[candidate.id] = { at: new Date().toISOString(), source: candidate.sourceText };
          break;
        }
        if (action === 's' || action === 'skip') break;
        if (action === 'q' || action === 'quit') return grouped;
        console.log('Choose a, e, c, d, s, or q.');
      }
    }
  } finally {
    rl.close();
  }

  return grouped;
}

const state = loadState();
const candidates = readSmsCandidates(state);

if (candidates.length === 0) {
  console.log('No new importable debit/credit SMS messages found.');
  process.exit(0);
}

const accounts = readAccounts();
if (accounts.length === 0) fail('No open Actual accounts found. Create an account first.');

if (previewOnly) {
  console.log(JSON.stringify({ accounts, candidates }, null, 2));
  process.exit(0);
}

let grouped;
if (nonInteractive) {
  if (!defaultAccountId) fail('Set ACTUAL_SMS_ACCOUNT_ID for non-interactive import.');
  const account = pickDefaultAccount(accounts);
  grouped = new Map([[account.id, candidates.map(candidate => candidate.transaction)]]);
  for (const candidate of candidates) {
    state.imported[candidate.id] = { at: new Date().toISOString(), accountId: account.id };
  }
} else {
  grouped = await reviewCandidates(candidates, accounts, state);
}

let importedCount = 0;
for (const [accountId, transactions] of grouped.entries()) {
  if (transactions.length === 0) continue;
  importTransactions(accountId, transactions);
  importedCount += transactions.length;
}

saveState(state);
console.log(`Imported ${importedCount} transaction(s).`);
console.log(`Review state: ${statePath}`);
EOF

cat > "$TOOLS_DIR/sms-to-actual.mjs" <<'EOF'
#!/usr/bin/env node
import { spawnSync } from 'node:child_process';

const result = spawnSync('node', [`${process.env.HOME}/actual-tools/sms-review.mjs`, '--auto-import', ...process.argv.slice(2)], {
  stdio: 'inherit',
});
process.exit(result.status ?? 1);
EOF
cat > "$TOOLS_DIR/actual-env.example" <<'EOF'
export ACTUAL_SERVER_URL=http://127.0.0.1:5006
export ACTUAL_PASSWORD='your-server-password'
export ACTUAL_SYNC_ID='your-budget-sync-id'
export ACTUAL_SMS_ACCOUNT_ID='your-account-id'
EOF

chmod +x "$TOOLS_DIR/run-actual.sh" "$TOOLS_DIR/watchdog.sh" "$TOOLS_DIR/sms-review.mjs" "$TOOLS_DIR/sms-to-actual.mjs"

cat > "$SERVICE_DIR/actual-budget/run" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
exec 2>&1
exec "$TOOLS_DIR/run-actual.sh"
EOF

cat > "$SERVICE_DIR/actual-budget/log/run" <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
exec svlogd -tt "$HOME/actual-logs"
EOF

cat > "$SERVICE_DIR/actual-watchdog/run" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
exec 2>&1
exec "$TOOLS_DIR/watchdog.sh"
EOF

cat > "$SERVICE_DIR/actual-watchdog/log/run" <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
exec svlogd -tt "$HOME/actual-watchdog-logs"
EOF

chmod +x "$SERVICE_DIR/actual-budget/run" "$SERVICE_DIR/actual-budget/log/run"
chmod +x "$SERVICE_DIR/actual-watchdog/run" "$SERVICE_DIR/actual-watchdog/log/run"

echo "Starting services..."
sv-enable actual-budget || true
sv-enable actual-watchdog || true
sv up actual-budget || true
sv up actual-watchdog || true

cat <<EOF

Done.

Open Actual on Android:
  http://$APP_HOST:$APP_PORT

Add that page to your home screen from Chrome for PWA-style use.

Useful commands:
  sv status actual-budget
  sv status actual-watchdog
  svlogtail actual-budget
  svlogtail actual-watchdog
  sh "$TOOLS_DIR/run-actual.sh"

SMS import:
  1. Install the Termux:API Android app from F-Droid.
  2. Grant SMS permission to Termux:API.
  3. Fill values from:
       $TOOLS_DIR/actual-env.example
  4. Preview accounts and parsed SMS candidates:
       node "$TOOLS_DIR/sms-review.mjs" --dry-run
  5. Review each spend, then approve/edit/decline:
       node "$TOOLS_DIR/sms-review.mjs"
  6. Optional non-interactive import to ACTUAL_SMS_ACCOUNT_ID:
       node "$TOOLS_DIR/sms-to-actual.mjs"

Important Android setting:
  Disable battery optimization for Termux.

EOF
