'use strict';

const { startLocalS3Fixture } = require('./local_s3_fixture.cjs');

async function main() {
  const bucket = process.env.ATERMIUS_FIXTURE_S3_BUCKET;
  const accessKeyId = process.env.ATERMIUS_FIXTURE_S3_ACCESS_KEY_ID;
  const controlToken = process.env.ATERMIUS_FIXTURE_S3_CONTROL_TOKEN;
  if (!bucket || !accessKeyId) throw new Error('loopback fixture configuration is incomplete');
  const fixture = await startLocalS3Fixture({ bucket, accessKeyId, controlToken });
  process.stdout.write(`${JSON.stringify({ ready: true, endpoint_url: fixture.endpointUrl })}\n`);

  let closing;
  const close = () => {
    if (!closing) {
      closing = fixture.close().then(() => process.exit(0));
    }
    return closing;
  };
  process.once('SIGINT', () => { void close(); });
  process.once('SIGTERM', () => { void close(); });
}

main().catch(() => {
  process.stderr.write('loopback S3 fixture failed to start\n');
  process.exitCode = 1;
});
