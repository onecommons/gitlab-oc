---
title: Work items sync configuration file
---

`sync.yml` is the one file on the `work-items-sync` branch that you edit by hand. It sits at the root of the branch, outside every installation's directory, and says which installations' directories on the branch each installation copies from. No installation writes it, and none deletes it.

For how to use it, see [Import work items from another installation](import.md) and [Transfer work items to another installation](transfer.md). For the branch layout, see [Work items sync file format](file_format.md).

## Example

This example has every key the file accepts. `staging` hands its issues to `prod` and goes away:

```yaml
---
_schema: sync@1              # required; sync@1 is the only value
_metadata: {}                # reserved for the format; nothing reads it today

staging:                     # a name you choose, meaningful only inside this file
  uuid: 1111-2222-3333-4444-555555555555   # required; names the directory on the branch
  .note: retiring this after Q3            # unknown keys beginning with "." are ignored, at any
                                           # level, instead of being an error
  sync:
    prod:                    # another name this file declares
      transfer: all          # or a list: [issues/42.yml, issues/57.yml]

prod:
  uuid: 6666-7777-8888-9999-000000000000
  sync:
    staging:
      import: all                # or: transferred
      user_mapping: username     # or: none, email — email if left out
      default_user: import-bot   # or: <ghost>, which is what it means if left out
```

The file has an installation block for each installation, a `sync` entry for each relationship, and four keys inside one. An installation with nothing to say about anybody needs only its `uuid`.

## Keys

Each top-level block names an installation. The name is yours to choose and means nothing outside this file. The `uuid` identifies the installation and matches its directory on the branch. An installation finds its own block by that UUID and reads the `sync` entries under it. In the example, `prod` copies everything in `staging`'s directory, and `staging` copies nothing.

To find an installation's UUID, go to **Settings** > **General** > **Work items sync**. The page shows it as "This installation's ID, for sync.yml:". It is also the name of the installation's directory on the branch. The UUIDs in the examples on this page are placeholders.

| Key | Goes in | Values | Default | Meaning |
|-----|---------|--------|---------|---------|
| `_schema` | Top level | `sync@1` | None. Required. | The version of the file format. `sync@1` is the only value. |
| `_metadata` | Top level | A mapping | None | Reserved for the format. Nothing reads it today. |
| `<name>.uuid` | Installation block | The installation's UUID | None. Required. | Identifies the installation and names its directory on the branch. |
| `<name>.sync.<peer>.import` | Peer entry | `all` or `transferred` | None | What this installation copies from the peer's directory. `all` copies everything. `transferred` copies only items the peer transfers. See [Import work items from another installation](import.md) and [Transfer work items to another installation](transfer.md). |
| `<name>.sync.<peer>.user_mapping` | Peer entry | `none`, `email`, or `username` | `email` | How users on imported items are matched to local users. See [Import work items from another installation](import.md). |
| `<name>.sync.<peer>.default_user` | Peer entry | A username or `<ghost>` | `<ghost>`, the Ghost User | The user who stands in where `user_mapping` finds no match. See [Import work items from another installation](import.md). |
| `<name>.sync.<peer>.transfer` | Peer entry | `all`, or a list of `issues/<n>.yml` paths | None | What this installation hands to the peer. See [Transfer work items to another installation](transfer.md). |

`<name>` is the name of an installation block, and `<peer>` is another name the file declares.

Withdrawing an entry stops copies being updated. It does not delete them. Removing the installation's directory from the branch does that.

## Rules

- Keys beginning with `_` belong to the format. `_schema` and `_metadata` are the only ones. Any other `_` key is a syntax error.
- Keys beginning with `.` are yours. Put whatever you like under them, at any level, and nothing reads them. Use them rather than YAML comments for anything you want to keep, because comments do not survive a rewrite of the file.
- `sync` with nothing under it, or a relationship with nothing under it, declares nothing and is not a mistake.
- A key given an empty value where one is required, such as `uuid:`, is a syntax error.
- Anchors, aliases, and `<<` merge keys work as YAML defines them. A `.` key is a good place to keep what you share.
- A key written out wins over one merged in.

This example shares settings with a merge key. The `staging` relationship imports everything, matches users on usernames, and sends the rest to `import-bot`:

```yaml
.common: &common
  import: all
  user_mapping: username

prod:
  uuid: 6666-7777-8888-9999-000000000000
  sync:
    staging:
      <<: *common
      default_user: import-bot
```

## Validation when you push

Any syntax error in `sync.yml` refuses the push, naming the line and the problem:

```plaintext
remote: GitLab: Work items sync: sync.yml:9: unknown key "improt" in "prod/sync/staging"; a peer instance section takes "import", "user_mapping", "default_user", "transfer"
```

Git adds `remote:` and GitLab adds `GitLab:` to every rejected push. Neither says which part of the system is talking. The rest of the line is this check.

Everywhere else, work items sync never fails a push over the branch contents. Only `sync.yml` can refuse a push.

### Syntax errors

These refuse the push:

- A key that is not one of the keys above, or the same key twice in one mapping.
- A value outside the list for its key, such as `import: everything`.
- An alias naming an anchor the file does not define, or the same anchor defined twice.
- A `default_user` that is not a well-formed username, or a keyword other than `<ghost>`. Only its shape is checked, never whether that account exists here.
- A transfer path that is not `issues/<number>.yml` relative to the giver's own directory, or that names a merge request.
- An installation syncing with itself, or with a name the file does not declare.
- Two installations sharing a `uuid`.
- The same item promised to two installations.
- A `transfer` the receiving installation declares no `import` for.
- A `sync.yml` larger than 64 KiB.

An installation also refuses a `_schema` it does not recognize. If a newer installation starts writing `sync@2`, pushing that branch to an older one is rejected until you upgrade it too. Nothing already on the branch is affected, only the push that introduces the newer file. Keep this in mind if you upgrade two installations at different times.

### What waits

Only what the file itself decides is checked: its syntax, its keys, and arrangements that contradict each other. Anything that depends on the state of an installation waits for a later run, because the other side cannot see it and it might become true later. For example:

- Whether the `default_user` exists.
- Whether an item is still there.
- Whether the other installation has pushed yet.

### Successful pushes

A push that changes the file and succeeds prints what the file now means:

```plaintext
remote: Work items sync: sync.yml updated. This instance is 'prod'.
remote:   imports all from staging
```

The message shows what the file asks for, not what came of it. The import runs immediately afterward in the background, so the outcome is not known yet. Two cases where a valid file does nothing are called out in this message because they are otherwise invisible:

- The file names no installation with this installation's UUID, so nothing on the branch is imported here.
- The person pushing is not an Owner or Planner of this project, so the push did not act on the file at all.

The push output also reports a file that cannot be read. When the file arrived by creating the branch, the push output is the only feedback.

### Pushes that are not checked

Two kinds of push are deliberately not checked:

- A push that leaves the file untouched.
- A push that creates the branch. A rebuild uses this kind of push to restore the branch after confidential content stops being allowed. The rebuild deletes the branch and re-commits everything on it, and a check that could refuse it would take every installation's directory with it. See [Confidential content in work items sync](confidential_content.md).

A file that arrives by creating the branch is inert rather than dangerous. A run that cannot read it imports nothing.

For the administrator's view, see [Work items sync administration](../../../administration/work_items_sync.md). For an overview of the feature, see [Work items sync](../work_items_sync.md).
