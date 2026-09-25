---
stage: Create
group: Source Code
description: Install a webhook that pushes changes from a GitHub repository to Unfurl Cloud.
title: Live mirroring from GitHub
---

<!-- OC Change -- a fork page: upstream has no GitHub live mirroring.
     Beside the pages that link to it, so the docs link check can resolve it. -->

Unfurl Cloud can install a webhook that automatically pushes changes from a GitHub
repository to Unfurl Cloud.

## Import from GitHub

To import a repository from GitHub, go to the **New project** page and select
[**Import project**](../../../../../projects/new#import_project):

1. Select **GitHub**.

   ![Import project page with GitHub listed as an import source.](img/import_project.png){width=640}

1. If GitHub asks you to authorize Unfurl Cloud, authorize the connection.

   ![GitHub authorization page for Unfurl Cloud by OneCommons.](img/github_auth.png){width=640}

1. Select the repositories and data you want to import.
   Imports can include issues, pull requests, labels, and other data.
   To prepare for the import, review the [prerequisites](../../import/github.md#prerequisites).

   ![GitHub repository import page with repository and data import options.](img/import_from_github.png){width=640}

1. After the import completes, confirm that the project displays the live mirroring banner.

   ![Project banner that identifies the upstream GitHub mirror.](img/mirror_banner.png){width=640}

## Configure live mirroring

To configure live mirroring after the import:

1. In the project, select **Settings** > **Repository**.

   ![Repository settings with manual sync and continuous mirroring controls.](img/mirror_settings.png){width=640}

1. To enable or disable live mirroring, select or clear **Enable continuous mirroring**.

1. To fetch the latest changes from the upstream GitHub repository, select **Sync Manually**.
