local util = (import '.github/jsonnet/index.jsonnet');

util.pipeline(
  'misc',
  [util.verifyJsonnet(fetch_upstream=false, runsOn='ubuntu-latest')],
) +
util.pipeline(
  'publish-prod',
  [
    util.yarnPublishJob(runsOn='ubuntu-latest'),
  ],
  event={ push: { branches: ['main'] } },
) +
util.pipeline(
  'pr',
  [
    util.ghJob(
      'test',
      image=null,
      useCredentials=false,
      runsOn='ubuntu-latest',
      steps=[
        util.checkout(ref='${{ github.event.pull_request.head.ref }}'),
        util.action('setup node',
                    'actions/setup-node@v3',
                    with={ 'node-version': 18 }),
        util.action(
          'Start MongoDB',
          'supercharge/mongodb-github-action@v1',
          with={
            'mongodb-version': 5.0,
            'mongodb-replica-set': 'rs0',
          }
        ),
        util.yarn(),
        util.step('test', 'yarn test'),
      ],
    ),
    util.yarnPublishPreviewJob(runsOn='ubuntu-latest', checkVersionBump=false),
  ],
)
