local util = (import '.github/jsonnet/index.jsonnet');

util.workflowJavascriptPackage(
  repositories=['gynzy', 'github'],
  packageManager='pnpm',
  branch='main',
  isPublicFork=true,
  testJob=util.ghJob(
    'test',
    image=null,
    useCredentials=false,
    runsOn='ubuntu-latest',
    steps=[
      util.pnpm.checkoutAndPnpm(
        ref='${{ github.event.pull_request.head.sha }}',
        source='gynzy',
      ),
      util.action(
        'Start MongoDB',
        'supercharge/mongodb-github-action@v1',
        with={
          'mongodb-version': 5.0,
          'mongodb-replica-set': 'rs0',
        }
      ),
      util.step('test', 'pnpm test'),
    ],
  ),
)
