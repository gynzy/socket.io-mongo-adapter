{
    setupPython()::
        $.step('pip install', 'python -m pip install --upgrade pip poetry') +
        $.step('poetry install', 'python -m poetry install'),
    runPytest()::
        $.step('pytest', 'poetry run pytest -vvv'),
    runLinting()::
        $.step('black', 'poetry run black --check --diff .') +
        $.step('isort', 'poetry run isort --check-only .') +
        $.step('ruff', 'poetry run ruff .'),
}