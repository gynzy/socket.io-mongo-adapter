{
  checkout(ifClause=null, fullClone=false, ref=null)::
    local with = (if fullClone then { 'fetch-depth': 0 } else {}) + (if ref != null then { ref: ref } else {});
    $.action(
      'Check out repository code',
      'actions/checkout@v3',
      with=with,
      ifClause=ifClause
    ),

  lint(service)::
    $.step('lint-' + service,
           './node_modules/.bin/eslint "./packages/' + service + '/{app,lib,tests,config,addon}/**/*.js" --quiet'),

  lintAll()::
    $.step('lint', 'yarn lint'),

  verifyGoodFences()::
    $.step('verify-good-fences', 'yarn run gf'),

  improvedAudit()::
    $.step('audit', 'yarn improved-audit'),

  verifyJsonnet(fetch_upstream=true, runsOn=null)::
    $.ghJob(
      'verify-jsonnet-gh-actions',
      image=$.jsonnet_bin_image,
      steps=[
              $.checkout(ref='${{ github.event.pull_request.head.sha }}'),
              $.step('remove-workflows', 'rm -f .github/workflows/*'),
            ] +
            (
              if fetch_upstream then [$.step('fetch latest lib-jsonnet',
                                             ' rm -rf .github/jsonnet/;\n                mkdir .github/jsonnet/;\n                cd .github;\n                curl https://files.gynzy.net/lib-jsonnet/v1/jsonnet-prod.tar.gz | tar xvzf -;\n              ')] else []
            )
            + [
              $.step('generate-workflows', 'jsonnet -m .github/workflows/ -S .github.jsonnet;'),
              $.step('git workaround', 'git config --global --add safe.directory $PWD'),
              $.step('check-jsonnet-diff', 'git diff --exit-code'),
              $.step(
                'possible-causes-for-error',
                'echo "Possible causes: \n' +
                '1. You updated jsonnet files, but did not regenerate the workflows. \n' +
                "To fix, run 'yarn github:generate' locally and commit the changes. If this helps, check if your pre-commit hooks work.\n" +
                '2. You used the wrong jsonnet binary. In this case, the newlines at the end of the files differ.\n' +
                'To fix, install the go binary. On mac, run \'brew uninstall jsonnet && brew install jsonnet-go\'"',
                ifClause='failure()',
              ),
            ],
      runsOn=runsOn,
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
    $.pipeline(
      'update-pr-description',
      event={
        pull_request: { types: ['opened'] },
      },
      jobs=[
        $.ghJob(
          'update-pr-description',
          steps=[
            $.action(
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
    $.action(
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
    $.pipeline(
      'purge-old-branches',
      [
        $.ghJob(
          'purge-old-branches',
          useCredentials=false,
          steps=[
            $.step('setup', 'apk add git bash'),
            $.checkout(),
            $.action(
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

  codiumAIPRAgent()::
    $.pipeline(
      'codium-ai',
      [
        $.ghJob(
          'pr_agent_job',
          useCredentials=false,
          ifClause='${{ github.event.pull_request.draft == false }}',
          steps=[
            $.action(
              'PR Agent action step',
              'gynzy/pr-agent@712f0ff0c37b71c676398f73c6ea0198eb9cdd03',
              env={
                OPENAI_KEY: $.secret('OPENAI_KEY'),
                GITHUB_TOKEN: $.secret('GITHUB_TOKEN'),
              }
            ),
          ]
        ),
      ],
      event={
        pull_request: {
          types: ['opened', 'reopened', 'ready_for_review'],
        },
        issue_comment: {},
      }
    ),
}