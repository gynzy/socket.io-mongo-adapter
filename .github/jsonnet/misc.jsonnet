local base = import 'base.jsonnet';
local images = import 'images.jsonnet';

{
  checkout(ifClause=null, fullClone=false, ref=null)::
    local with = (if fullClone then { 'fetch-depth': 0 } else {}) + (if ref != null then { ref: ref } else {});
    base.action(
      'Check out repository code',
      'actions/checkout@v3',
      with=with,
      ifClause=ifClause
    ) +
    base.step('git safe directory', "command -v git && git config --global --add safe.directory '*' || true"),

  lint(service)::
    base.step('lint-' + service,
              './node_modules/.bin/eslint "./packages/' + service + '/{app,lib,tests,config,addon}/**/*.js" --quiet'),

  lintAll()::
    base.step('lint', 'yarn lint'),

  verifyGoodFences()::
    base.step('verify-good-fences', 'yarn run gf'),

  improvedAudit()::
    base.step('audit', 'yarn improved-audit'),

  verifyJsonnetWorkflow()::
    base.pipeline(
      'misc',
      [
        self.verifyJsonnet(fetch_upstream=false),
      ],
      event='pull_request',
    ),

  verifyJsonnet(fetch_upstream=true, runsOn=null)::
    base.ghJob(
      'verify-jsonnet-gh-actions',
      runsOn=runsOn,
      image=images.jsonnet_bin_image,
      steps=[
              self.checkout(ref='${{ github.event.pull_request.head.sha }}'),
              base.step('remove-workflows', 'rm -f .github/workflows/*'),
            ] +
            (
              if fetch_upstream then [base.step('fetch latest lib-jsonnet',
                                                ' rm -rf .github/jsonnet/;\n                mkdir .github/jsonnet/;\n                cd .github;\n                curl https://files.gynzy.net/lib-jsonnet/v1/jsonnet-prod.tar.gz | tar xvzf -;\n              ')] else []
            )
            + [
              base.step('generate-workflows', 'jsonnet -m .github/workflows/ -S .github.jsonnet;'),
              base.step('git workaround', 'git config --global --add safe.directory $PWD'),
              base.step('check-jsonnet-diff', 'git diff --exit-code'),
              base.step(
                'possible-causes-for-error',
                'echo "Possible causes: \n' +
                '1. You updated jsonnet files, but did not regenerate the workflows. \n' +
                "To fix, run 'yarn github:generate' locally and commit the changes. If this helps, check if your pre-commit hooks work.\n" +
                '2. You used the wrong jsonnet binary. In this case, the newlines at the end of the files differ.\n' +
                'To fix, install the go binary. On mac, run \'brew uninstall jsonnet && brew install jsonnet-go\'"',
                ifClause='failure()',
              ),
            ],
    ),

  updatePRDescriptionPipeline(
    bodyTemplate,
    titleTemplate='',
    baseBranchRegex='[a-z\\d-_.\\\\/]+',
    headBranchRegex='[a-z]+-\\d+',
    bodyUpdateAction='suffix',
    titleUpdateAction='prefix',
    otherOptions={},
  )::
    base.pipeline(
      'update-pr-description',
      event={
        pull_request: { types: ['opened'] },
      },
      jobs=[
        base.ghJob(
          'update-pr-description',
          steps=[
            base.action(
              'update-pr-description',
              'gynzy/pr-update-action@v2',
              with={
                'repo-token': '${{ secrets.GITHUB_TOKEN }}',
                'base-branch-regex': baseBranchRegex,
                'head-branch-regex': headBranchRegex,
                'title-template': titleTemplate,
                'body-template': bodyTemplate,
                'body-update-action': bodyUpdateAction,
                'title-update-action': titleUpdateAction,
              } + otherOptions,
            ),
          ],
          useCredentials=false,
        ),
      ],
      permissions={
        'pull-requests': 'write',
      },
    ),

  shortServiceName(name)::
    assert name != null;
    std.strReplace(std.strReplace(name, 'gynzy-', ''), 'unicorn-', ''),

  secret(secretName)::
    '${{ secrets.' + secretName + ' }}',

  pollUrlForContent(url, expectedContent, name='verify-deploy', attempts='100', interval='2000', ifClause=null)::
    base.action(
      name,
      'gynzy/wait-for-http-content@v1',
      with={
        url: url,
        expectedContent: expectedContent,
        attempts: attempts,
        interval: interval,
      },
      ifClause=ifClause,
    ),

  cleanupOldBranchesPipelineCron()::
    base.pipeline(
      'purge-old-branches',
      [
        base.ghJob(
          'purge-old-branches',
          useCredentials=false,
          steps=[
            base.step('setup', 'apk add git bash'),
            self.checkout(),
            base.action(
              'Run delete-old-branches-action',
              'beatlabs/delete-old-branches-action@6e94df089372a619c01ae2c2f666bf474f890911',
              with={
                repo_token: '${{ github.token }}',
                date: '3 months ago',
                dry_run: false,
                delete_tags: false,
                extra_protected_branch_regex: '^(main|master|gynzy|upstream)$',
                extra_protected_tag_regex: '^v.*',
                exclude_open_pr_branches: true,
              },
              env={
                GIT_DISCOVERY_ACROSS_FILESYSTEM: 'true',
              }
            ),
          ],
        ),
      ],
      event={
        schedule: [{ cron: '0 12 * * 1' }],
      },
    ),

  // Test if the changed files match the given glob patterns.
  // Can test for multiple pattern groups, and sets multiple outputs.
  //
  // Parameters:
  // changedFiles: a map of grouped glob patterns to test against.
  //   The map key is the name of the group.
  //   The map value is a list of glob patterns (as string, can use * and **) to test against.
  //
  // Outputs:
  // steps.changes.outputs.<group>: true if the group matched, false otherwise
  //
  // Permissions:
  // Requires the 'pull-requests': 'read' permission
  //
  // Example:
  // misc.testForChangedFiles({
  //   'app': ['packages/*/app/**/*', 'package.json'],
  //   'lib': ['packages/*/lib/**/*'],
  // })
  //
  // This will set the following outputs:
  // - steps.changes.outputs.app: true if any of the changed files match the patterns in the 'app' group
  // - steps.changes.outputs.lib: true if any of the changed files match the patterns in the 'lib' group
  //
  // These can be tested as in an if clause as follows:
  // if: steps.changes.outputs.app == 'true'
  //
  // See https://github.com/dorny/paths-filter for more information.
  testForChangedFiles(changedFiles, headRef=null, baseRef=null)::
    [
      base.step('git safe directory', 'git config --global --add safe.directory $PWD'),
      base.action(
        'check-for-changes',
        uses='dorny/paths-filter@v2',
        id='changes',
        with={
               filters: |||
                 %s
               ||| % std.manifestYamlDoc(changedFiles),
               token: '${{ github.token }}',
             } +
             (if headRef != null then { ref: headRef } else {}) +
             (if baseRef != null then { base: baseRef } else {}),
      ),
    ],

  // Wait for the given jobs to finish.
  // Exits successfully if all jobs are successful, otherwise exits with an error.
  //
  // Parameters:
  // name: the name of the github job
  // jobs: a list of job names to wait for
  //
  // Returns:
  // a job that waits for the given jobs to finish
  awaitJob(name, jobs)::
    local dependingJobs = std.flatMap(
      function(job)
        local jobNameArray = std.objectFields(job);
        if std.length(jobNameArray) == 1 then [jobNameArray[0]] else [],
      jobs
    );
    [
      base.ghJob(
        'await-' + name,
        ifClause='${{ always() }}',
        needs=dependingJobs,
        useCredentials=false,
        steps=[
          base.step(
            'success',
            'exit 0',
            ifClause="${{ contains(join(needs.*.result, ','), 'success') }}"
          ),
          base.step(
            'failure',
            'exit 1',
            ifClause="${{ contains(join(needs.*.result, ','), 'failure') }}"
          ),
        ],
      ),
    ],

  // Post a job to a kubernetes cluster
  //
  // Parameters:
  // name: the name of the github job
  // job_name: the name of the job to be posted
  // cluster: the cluster to post the job to. This should be an object from the clusters module
  // image: the image to use for the job
  // environment: a map of environment variables to pass to the job
  // command: the command to run in the job (optional)
  postJob(name, job_name, cluster, image, environment, command='')::
    base.action(
      name,
      'docker://' + images.job_poster_image,
      env={
        JOB_NAME: job_name,
        IMAGE: image,
        COMMAND: command,
        ENVIRONMENT: std.join(' ', std.objectFields(environment)),
        GCE_JSON: cluster.secret,
        GKE_PROJECT: cluster.project,
        GKE_ZONE: cluster.zone,
        GKE_CLUSTER: cluster.name,
        NODESELECTOR_TYPE: cluster.jobNodeSelectorType,
      } + environment,
    ),
}
