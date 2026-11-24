import { expect, test } from 'bun:test';
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

test('独立二进制加载外部 TypeScript，限制权限并强杀失控子进程', async () => {
  const root = mkdtempSync(join(realpathSync(tmpdir()), 'wmb-compiled-test-'));
  const sourceDir = join(root, 'src');
  const standalone = join(root, 'standalone');
  const stages = join(root, 'stages');
  let networkRequests = 0;
  const network = Bun.serve({
    hostname: '127.0.0.1', port: 0,
    fetch() { networkRequests++; return new Response('test'); },
  });
  let processUnderTest: ReturnType<typeof Bun.spawn> | undefined;
  try {
    for (const dir of [sourceDir, standalone, stages]) mkdirSync(dir, { mode: 0o700 });
    const host = resolve(import.meta.dir, '../src/plugins/worker-host.ts');
    const fixture = join(sourceDir, 'host.ts');
    writeFileSync(fixture, `
      import { readFileSync } from 'node:fs';
      import { join } from 'node:path';
      import { PluginWorkerHost, runPluginWorkerCli } from ${JSON.stringify(host)};
      if (!await runPluginWorkerCli()) {
        const root = process.argv[2];
        const results: unknown[] = [];
        const healthy = () => ({ title: 'host-healthy' });
        for (const name of ['normal', 'denied', 'throw', 'rejection', 'spin', 'pending', 'normal']) {
          const entry = join(root, 'plugins', 'modules', name, 'index.ts');
          let workerPid: number | undefined;
          const worker = new PluginWorkerHost({ entry, pluginId: name, source: readFileSync(entry),
            timeoutMs: 700, approvedPermissions: ['notify'],
            handlers: {
              'emit.feed': (_signal, item) => { results.push(item.body); },
              log: (_signal, _level, message) => { workerPid = Number(message); },
              'emit.wechat': () => { results.push('unexpected-send'); },
            },
          });
          const start = performance.now();
          try { await worker.invoke('onInit'); results.push('ok'); }
          catch (error) { results.push((error as Error).message); }
          finally {
            const elapsed = performance.now() - start;
            worker.dispose();
            if (workerPid) {
              for (let i = 0; i <= 20; i++) {
                try { process.kill(workerPid, 0); }
                catch (error) {
                  if ((error as NodeJS.ErrnoException).code === 'ESRCH') break;
                  throw error;
                }
                if (i === 20) throw new Error('worker survived disposal');
                await Bun.sleep(10);
              }
            }
            if (name === 'spin' || name === 'pending') results.push(elapsed < 1500);
          }
        }
        console.log(JSON.stringify({ results, ...healthy() }));
      }
    `);
    const binary = join(standalone, 'bridge-engine');
    const compile = Bun.spawnSync([process.execPath, 'build', '--compile', '--no-compile-autoload-dotenv',
      '--no-compile-autoload-bunfig', fixture, '--outfile', binary]);
    expect(compile.stderr.toString()).toBe('');
    expect(compile.exitCode).toBe(0);
    rmSync(sourceDir, { recursive: true });

    const secret = join(root, 'private.txt');
    writeFileSync(secret, 'private-content');
    const plugins: Record<string, string> = {
      normal: `
        import { readFileSync, writeFileSync } from 'node:fs';
        export default { async onInit(ctx: any) {
          const value: number = 42;
          let denied = 0;
          try { readFileSync(${JSON.stringify(secret)}); } catch { denied++; }
          try { writeFileSync(${JSON.stringify(join(root, 'unexpected.txt'))}, 'violation'); } catch { denied++; }
          try { await fetch(${JSON.stringify(network.url.href)}); } catch { denied++; }
          await ctx.emit.feed({ title: 'loaded', body: String(value) + ':' + denied });
        } };
      `,
      denied: "export default { onInit(ctx: any) { return ctx.emit.wechat({ conversationId: 'filehelper', text: 'test', dedupeKey: '1' }); } };",
      throw: "export default { onInit() { throw new Error('private error'); } };",
      rejection: "export default { async onInit() { throw new Error('private rejection'); } };",
      spin: "export default { async onInit(ctx: any) { await ctx.log('info', String(process.pid)); while (true) {} } };",
      pending: "export default { async onInit(ctx: any) { await ctx.log('info', String(process.pid)); return new Promise(() => {}); } };",
    };
    for (const [id, source] of Object.entries(plugins)) {
      const directory = join(standalone, 'plugins', 'modules', id);
      mkdirSync(directory, { recursive: true, mode: 0o700 });
      writeFileSync(join(directory, 'index.ts'), source, { mode: 0o600 });
    }
    processUnderTest = Bun.spawn([binary, standalone], {
      cwd: standalone, stdout: 'pipe', stderr: 'pipe', env: { TMPDIR: stages },
    });
    const [stdout, stderr, code] = await Promise.all([
      new Response(processUnderTest.stdout as ReadableStream).text(),
      new Response(processUnderTest.stderr as ReadableStream).text(),
      processUnderTest.exited,
    ]);
    expect(stderr).toBe('');
    expect(code).toBe(0);
    expect(JSON.parse(stdout)).toEqual({ title: 'host-healthy',
      results: ['42:3', 'ok', 'permission-denied', 'internal-error', 'internal-error',
        'plugin-timeout', true, 'plugin-timeout', true, '42:3', 'ok'] });
    expect(readdirSync(stages)).toEqual([]);
    expect(readFileSync(secret, 'utf8')).toBe('private-content');
    expect(networkRequests).toBe(0);
  } finally {
    network.stop(true);
    processUnderTest?.kill('SIGKILL');
    await processUnderTest?.exited;
    rmSync(root, { recursive: true, force: true });
  }
}, 30_000);
