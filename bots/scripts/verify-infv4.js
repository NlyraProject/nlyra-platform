'use strict';
// verify-infv4: el mismo camino que verify-v4.js (Sourcify v2 + Blockscout standard-input con UA). La direccion sale de desk-addresses.json.
const fs = require('fs');
const A = JSON.parse(fs.readFileSync((process.env.DESK_ADDRESSES || require('path').join(__dirname, '../../deployments/desk-addresses.json')), 'utf8'));
const ADDR = A.infinityGridV4, NAME = 'ArchitectInfinityGridV4', CHAIN_ID = 4663;
if (!ADDR) { console.log('infinityGridV4 sin deployar (no esta en desk-addresses.json)'); process.exit(1); }
const BS = 'https://robinhoodchain.blockscout.com', SOURCIFY = 'https://sourcify.dev/server';
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36';
const input = JSON.parse(fs.readFileSync(require('path').join(__dirname, '../artifacts/ArchitectInfinityGridV4/ArchitectInfinityGridV4.input.json'), 'utf8'));
const file = Object.keys(input.sources).find((k) => k.endsWith('ArchitectInfinityGridV4.sol'));
const v = require('solc').version();
const compilerVersion = v.split('.Emscripten')[0];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
(async () => {
  console.log('compiler', compilerVersion, '· file', file, '· fuentes', Object.keys(input.sources).length, '· viaIR', input.settings.viaIR, '· evm', input.settings.evmVersion, '· runs', input.settings.optimizer && input.settings.optimizer.runs);
  let st = await (await fetch(`${SOURCIFY}/v2/contract/${CHAIN_ID}/${ADDR}`)).json().catch(() => ({}));
  console.log('sourcify antes:', st.match || 'none');
  if (!st.match) {
    const r = await fetch(`${SOURCIFY}/v2/verify/${CHAIN_ID}/${ADDR}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ stdJsonInput: input, compilerVersion, contractIdentifier: `${file}:${NAME}` }) });
    const t = await r.text();
    console.log('sourcify submit HTTP', r.status, t.slice(0, 160));
    if (r.ok) {
      const id = JSON.parse(t).verificationId;
      for (let i = 0; i < 20; i++) { await sleep(4000); const j = await (await fetch(`${SOURCIFY}/v2/verify/${id}`)).json(); if (j.isJobCompleted) { console.log('sourcify job:', j.error ? 'ERROR ' + JSON.stringify(j.error).slice(0, 200) : 'done'); break; } }
    }
    st = await (await fetch(`${SOURCIFY}/v2/contract/${CHAIN_ID}/${ADDR}`)).json().catch(() => ({}));
    console.log('sourcify ahora:', st.match || 'none');
  }
  const form = new FormData();
  form.append('compiler_version', compilerVersion); form.append('license_type', 'mit'); form.append('contract_name', NAME); form.append('autodetect_constructor_args', 'true');
  form.append('files[0]', new Blob([JSON.stringify(input)], { type: 'application/json' }), 'standard-input.json');
  const rb = await fetch(`${BS}/api/v2/smart-contracts/${ADDR}/verification/via/standard-input`, { method: 'POST', body: form, headers: { 'user-agent': UA } });
  const tb = await rb.text().catch(() => '');
  console.log('blockscout submit HTTP', rb.status, tb.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').slice(0, 120));
  await sleep(8000);
  const c = await (await fetch(`${BS}/api/v2/smart-contracts/${ADDR}`, { headers: { 'user-agent': UA } })).json().catch(() => ({}));
  console.log('blockscout estado: is_verified', c.is_verified, '· partial', c.is_partially_verified, '· name', c.name);
})().catch((e) => { console.log('ERR', e.message); process.exit(1); });
