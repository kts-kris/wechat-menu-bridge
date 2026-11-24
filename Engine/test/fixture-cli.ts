import { event, mockNetwork } from './fixture.ts';

// Only started by tests; this second port isn't compiled into the app.
// --v2 serves the MCP v2 surface the bundled v3 engine probes (tools/list, conversations).
const f = await mockNetwork({ v2: process.argv.includes('--v2') });
let serial = 0;
const control = Bun.serve({ hostname: '127.0.0.1', port: 0, fetch(req) {
  const path = new URL(req.url).pathname;
  if (req.method === 'POST' && path === '/push') f.push(event(`swift-${++serial}`));
  else if (req.method === 'POST' && path === '/peer-stop') f.push(event(`swift-${++serial}`, { text: '别再自动回复了' }));
  else if (req.method === 'POST' && path === '/gap') {
    f.state.gap = true;
    f.push(event(`swift-${++serial}`));
  } else if (req.method === 'POST' && path === '/gap-clear') f.state.gap = false;
  else if (req.method === 'POST' && path === '/drop') f.state.sendDrop = true;
  else if (req.method === 'POST' && path === '/delivered') f.state.operationsDelivery = 'delivered';
  else if (req.method !== 'GET' || path !== '/counts') return new Response(null, { status: 404 });
  const submitted = f.calls.filter(c => c.name === 'messages.send_text');
  const last = submitted.at(-1)?.args;
  return Response.json({ sends: submitted.length, models: f.models.length,
    waits: f.calls.filter(c => c.name === 'events.wait').length, faults: f.wireFaults.length,
    last: last && { account: last.account_id, peer: last.conversation_id, text: last.text } });
} });
console.log(JSON.stringify({ mcp: f.mcp, model: f.model, control: control.url.href }));
async function close() { control.stop(true); await f.close(); process.exit(0); }
if (process.argv.includes('--until-terminated')) process.once('SIGTERM', close);
else { process.stdin.resume(); process.stdin.once('end', close); }
