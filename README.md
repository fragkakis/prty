<img src="docs/icon.png" width="96" alt="">

# Prty

A macOS menu-bar app that lists the GitHub pull requests waiting on you, and notifies you when something happens on them. A small replacement for [Trailer](https://github.com/ptsochantaris/trailer).

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshot-dark.png">
  <img src="docs/screenshot-light.png" alt="The Prty panel, showing the To review and My PRs tabs">
</picture>

## Features

- **To review:** PRs requesting your review (marked *You*) or your teams' review, newest first, then open PRs you've already reviewed. Team requests idle for 30+ days are hidden.
- **My PRs:** your open PRs with their review state (approved, changes requested, awaiting review).
- **Grouped by repo:** click a repo to collapse it; remembered across launches.
- **Filter:** type to filter by number (`#123`), title, repo, author or reviewer. Every word must match.
- **Unread dots:** a blue dot marks new activity you haven't opened. Clicking the PR or its notification opens it on GitHub and clears the dot.
- **Badge:** the menu-bar icon shows how many PRs await your review.

### Notifications

- Reviews, approvals and comments on your PRs
- New review requests to you or your teams
- Comments, reviews and pushes on PRs you review
- Merges of your PRs and of PRs you review

Your own actions are ignored, including your own merges unless auto-merge did them. *Ignore bots* (on by default) hides PRs opened by bots such as dependabot and mutes bot comments. Each kind can be turned off in Settings.

## Requirements

- macOS 15 or later
- Xcode Command Line Tools (`xcode-select --install`); full Xcode isn't needed
- [GitHub CLI](https://cli.github.com), logged in with `gh auth login`. Prty reuses its token, so there's nothing else to configure.

## Install

```sh
git clone https://github.com/fragkakis/prty.git
cd prty
make install   # builds, ad-hoc signs, copies to ~/Applications/Prty.app and launches it
```

Allow notifications when macOS asks. To start Prty at login, turn on *Launch at login* in Settings (⌘, in the panel).

## Development

```sh
make test      # unit tests
make run       # build and launch from .build/ without installing
make logs      # stream poll logs (one line per poll: requests, cost, duration)
make icon      # redraw Resources/AppIcon.icns from Scripts/icon.swift
```

- **API usage:** one GraphQL request per poll (every 2 min by default), about 20 of the 5,000 points GitHub allows per hour, plus a 1-point lookup when a PR drops off your lists (to tell merged from closed). Polling pauses when the rate limit runs low.
- **State:** `~/Library/Application Support/Prty/state.json` holds what was already seen, so restarts don't re-notify.
- **Debug:** `defaults write com.fragkakis.prty notifySelf -bool YES` counts your own comments as activity, so you can test notifications on your own PR.

## License

[MIT](LICENSE)
