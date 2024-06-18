local base = import 'base.jsonnet';

{
  install(args=[], with={})::
    base.action(
      'Install application code',
      'pnpm/action-setup@v2',
      with={
        version: '^8.14.0',
        run_install: |||
          - args: %(args)s
        ||| % { args: args },
      }
    ),
}
