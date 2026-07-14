# Development workflow

- After every change to the macOS app, build the release app with `./scripts/build-app.sh`, replace `/Applications/taskboard.app` with the newly built `dist/taskboard.app`, and relaunch the installed app before handing the change back to the user.
