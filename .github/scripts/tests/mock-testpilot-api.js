const http = require('http');

const port = Number(process.argv[2]);
const mode = process.argv[3] || 'success';
const expectedCredential = 'local-test-credential';
const expectedMetadata = {
  environmentId: 42,
  pipelineId: '9001',
  jobId: 'execute-testpilot-cycle',
  commitSha: '0123456789abcdef0123456789abcdef01234567',
  branch: 'main'
};
const submissions = new Map();
let nextRunId = 701;

if (!Number.isSafeInteger(port) || port < 1024 || port > 65535) {
  process.stderr.write('A valid test port is required.\n');
  process.exit(2);
}

function send(response, statusCode, body) {
  const content = typeof body === 'string' ? body : JSON.stringify(body);
  response.writeHead(statusCode, {
    'content-type': 'application/json',
    'content-length': Buffer.byteLength(content)
  });
  response.end(content);
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    request.on('data', chunk => chunks.push(chunk));
    request.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    request.on('error', reject);
  });
}

function terminalStatus(state) {
  if (mode === 'timeout') {
    return 'QUEUED';
  }
  if (state.polls === 0) {
    return 'QUEUED';
  }
  if (state.polls === 1) {
    return 'RUNNING';
  }
  return mode === 'failure' ? 'FAILED' : 'PASSED';
}

function executionResponse(state) {
  const status = terminalStatus(state);
  const passed = status === 'PASSED';
  const failed = status === 'FAILED';
  return {
    runId: state.runId,
    projectId: 5,
    cycleId: 2,
    environmentId: 42,
    status,
    trigger: 'CI_CD',
    queuedAt: '2026-07-30T08:00:00',
    startedAt: status === 'QUEUED' ? null : '2026-07-30T08:00:01',
    finishedAt: passed || failed ? '2026-07-30T08:00:13.5' : null,
    durationMs: passed || failed ? 12500 : null,
    metadata: {
      pipelineId: expectedMetadata.pipelineId,
      jobId: expectedMetadata.jobId,
      commitSha: expectedMetadata.commitSha,
      branch: expectedMetadata.branch
    },
    result: {
      totalCases: 2,
      readyCases: 2,
      passedCases: passed ? 2 : 0,
      failedCases: failed ? 1 : 0,
      skippedCases: 0,
      environmentErrors: 0,
      totalSteps: 4,
      passedSteps: passed ? 4 : 2,
      failedSteps: failed ? 1 : 0,
      totalAssertions: 2,
      passedAssertions: passed ? 2 : 1,
      failedAssertions: failed ? 1 : 0,
      cases: [{
        testCaseId: 1,
        title: 'Mock case',
        status: failed ? 'FAILED' : passed ? 'PASSED' : status,
        reason: failed ? 'Expected mock assertion failure.' : null,
        durationMs: passed || failed ? 6000 : null,
        artifacts: passed || failed
          ? { report: 'execution-runs/1/testpilot-cypress-report.json' }
          : {}
      }]
    },
    technicalFailure: null
  };
}

const server = http.createServer(async (request, response) => {
  if (request.headers.authorization !== `Bearer ${expectedCredential}`) {
    send(response, 401, { message: 'Invalid test credential.' });
    return;
  }
  if (mode === 'forbidden') {
    send(response, 403, { message: 'Credential scope is insufficient.' });
    return;
  }

  const submitMatch = request.url.match(/^\/api\/v1\/projects\/5\/test-cycles\/2\/executions$/);
  if (request.method === 'POST' && submitMatch) {
    if (mode === 'malformed') {
      send(response, 202, '{"runId":');
      return;
    }
    const idempotencyKey = request.headers['idempotency-key'];
    const rawBody = await readBody(request);
    let parsedBody;
    try {
      parsedBody = JSON.parse(rawBody);
    } catch {
      send(response, 400, { message: 'Request JSON was malformed.' });
      return;
    }
    if (!idempotencyKey
      || Object.entries(expectedMetadata).some(([key, value]) => parsedBody[key] !== value)) {
      send(response, 400, { message: 'Metadata or Idempotency-Key was invalid.' });
      return;
    }

    const existing = submissions.get(idempotencyKey);
    if (existing && existing.rawBody !== rawBody) {
      send(response, 409, { message: 'Idempotency-Key request mismatch.' });
      return;
    }
    const state = existing || {
      runId: nextRunId++,
      polls: 0,
      rawBody
    };
    submissions.set(idempotencyKey, state);
    send(response, 202, {
      runId: state.runId,
      status: terminalStatus(state),
      statusUrl: `/api/v1/execution-runs/${state.runId}`
    });
    return;
  }

  const statusMatch = request.url.match(/^\/api\/v1\/execution-runs\/(\d+)$/);
  if (request.method === 'GET' && statusMatch) {
    const state = [...submissions.values()]
      .find(candidate => candidate.runId === Number(statusMatch[1]));
    if (!state) {
      send(response, 404, { message: 'Execution run not found.' });
      return;
    }
    const body = executionResponse(state);
    state.polls++;
    send(response, 200, body);
    return;
  }

  send(response, 404, { message: 'Mock endpoint not found.' });
});

server.listen(port, '127.0.0.1', () => {
  process.stdout.write(`READY ${port} ${mode}\n`);
});

function shutdown() {
  server.close(() => process.exit(0));
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
