local base = import 'base.jsonnet';
local images = import 'images.jsonnet';
local misc = import 'misc.jsonnet';
local yarn = import 'yarn.jsonnet';

{
  /**
   * Creates a GitHub Actions job to post deployment information to New Relic.
   *
   * @param {array} apps - Array of application objects containing deployment information
   * @param {string} [cacheName=null] - Name of the cache to use for yarn dependencies
   * @param {string} [source='gynzy'] - Registry source ('gynzy' or 'github') for npm packages
   * @param {string} [image='mirror.gcr.io/node:20.17'] - Docker image to use for the job
   * @param {boolean} [useCredentials=false] - Whether to use Docker registry credentials
   * @returns {jobs} - GitHub Actions job definition for New Relic deployment notification
   */
  postReleaseToNewRelicJob(
    apps,
    cacheName=null,
    source='gynzy',
    image='mirror.gcr.io/node:20.17',
    useCredentials=false,
  )::
    base.ghJob(
      'post-newrelic-release',
      image=image,
      useCredentials=useCredentials,
      ifClause="${{ github.event.deployment.environment == 'production' }}",
      steps=[
        yarn.checkoutAndYarn(ref='${{ github.sha }}', cacheName=cacheName, source=source),
        base.step(
          'post-newrelic-release',
          'node .github/scripts/newrelic.js',
          env={
            NEWRELIC_API_KEY: misc.secret('NEWRELIC_API_KEY'),
            NEWRELIC_APPS: std.join(
              ' ', std.flatMap(
                function(app)
                  if std.objectHas(app, 'newrelicApps') then
                    app.newrelicApps else [],
                apps
              )
            ),
            GIT_COMMIT: '${{ github.sha }}',
            DRONE_SOURCE_BRANCH: '${{ github.event.deployment.payload.branch }}',
          }
        ),
      ],
    ),
}
