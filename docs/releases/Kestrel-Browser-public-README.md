# Kestrel Browser

A native browser for macOS, built with Apple WebKit.

[![Latest release](https://img.shields.io/github/v/release/shay2000/Kestrel-Browser?display_name=tag&label=latest%20release&color=7657C8)](https://github.com/shay2000/Kestrel-Browser/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/shay2000/Kestrel-Browser/total?label=downloads&color=5482C8)](https://github.com/shay2000/Kestrel-Browser/releases)
![macOS 14 or later](https://img.shields.io/badge/macOS-14%2B-111111?logo=apple&logoColor=white)
![Apple WebKit](https://img.shields.io/badge/engine-Apple%20WebKit-2E7D80)
![Source code private for now](https://img.shields.io/badge/source-private%20for%20now-6B5CA5)

[Download the latest Kestrel Browser release](https://github.com/shay2000/Kestrel-Browser/releases/latest/download/Kestrel-Browser.zip) · [Release notes](https://github.com/shay2000/Kestrel-Browser/releases/latest)

Kestrel brings focused browsing, flexible split panes and a configurable assistant together in a Mac-first app.

## Features

- Independent browser panes with their own address bars and navigation.
- Custom keyboard shortcuts, tab groups and pinned pages.
- An assistant with optional web search and page context. Choose a provider in Settings.
- Local browser preferences and WebKit website storage.
- Built-in update checks, with **Kestrel → Check for Updates…** for a manual check.

Kestrel uses Apple's WebKit engine. Chromium extensions are not fully supported. Assistant page text may be sent to the selected provider when you use the assistant; review the provider and privacy controls in Settings.

## Screenshots

### New Tab with colourful pins and student tabs

![Kestrel New Tab with colourful pinned sites, Google Docs, Drive, Classroom, Gmail and Calendar tabs, and saved website shortcuts.](screenshots/new-tab.png)

The New Tab page brings search, pinned sites, open tabs and saved website shortcuts together. The sidebar shows public Google product pages and Khan Academy without signed-in accounts or private documents.

### Split view

![Kestrel showing Apple and Wikipedia in independent side-by-side panes.](screenshots/split-view.png)

Each pane has its own address bar and page controls.

### Assistant beside a study page

![Kestrel's Assistant sidebar beside Khan Academy's public student landing page, with the model picker above the composer.](screenshots/assistant-sidebar.png)

Keep the Assistant beside a page while you browse. This capture uses Khan Academy's public landing page and contains no student account or document content.

### Assistant page

![Kestrel's standalone Assistant page with a solid header and the model picker above the message composer.](screenshots/assistant.png)

Choose a provider above the composer. Web search is managed in Settings.

### Custom keyboard shortcuts

![Kestrel Settings showing editable shortcuts for tabs and split view.](screenshots/shortcuts.png)

Change bindings in Settings → Shortcuts, including the split-view keys.

## Requirements

- macOS 14 or later.
- Apple silicon or Intel Mac.

## Install

Download `Kestrel-Browser.zip`, open it, then move `Kestrel.app` to Applications. This first release is ad-hoc signed and is not notarized; macOS may show a Gatekeeper warning when you first open it. We will label signing and notarization status for each release.

## Source code

Source code is private for now. I plan to attach it only after cleaning up the code and verifying that identifying marks have been removed. For now, this repository contains prebuilt releases, screenshots and release notes only.
