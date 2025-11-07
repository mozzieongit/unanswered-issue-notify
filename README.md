# Reminder about unanswered and unassigned/unlabelled issues

A script that fetches GitHub Issues for specified repositories and checks for issues that have:
1. No labels, and
2. No assignee(s), and
3. No comments from a member of the specified GitHub Organization

If unanswered issues have been found, it uses `sendmail` to send an aggregated report for the repositories with unanswered issues to your recipient of choice.

## Dependencies

- `jq`
- `gh` (GitHub CLI)
- `sendmail`

## Usage

```text
Usage: ./reminder.sh [OPTIONS] -t <recipient> <repository...>

Notify the recipient via e-mail about unanswered GitHub issues, if they are older than '--until' and have no labels or assignees.

Requires jq, gh, and sendmail.

Options:
  -t, --to            Specify the email address to send the reminder mail to
  -f, --from          Specify the email address to send the reminder mail from [default: $USER@$HOSTNAME]
      --subject       Specify the email subject for the reminder mail [default: Reminder about unanswered issues in <repository>]
  -o, --org           Specify the GitHub organization to fetch the members list [default: NLnetLabs]
  -s, --since         Specify how old issues should maximally be to be fetched and checked for comments [default: 7 days ago]
  -u, --until         Specify how old issues should be at least to be considered unanswered [default: 2 days ago]
  -a, --account       Specify the sendmail account to use [default: default]
      --cat           Print the resulting e-mail to the terminal instead of sending it out (makes '-t' optional)
  -h, --help          Print this help text
```


## Example e-mail

```mail
To: your-email@exmaple.com
From: your-email@exmaple.com
Subject: Reminder about unanswered issues in mozzieongit/second-test, mozzieongit/test-repo

There are issues without answers from members of the specified org.

Org: NLnetLabs
Checked repos: NLnetLabs/cascade mozzieongit/test-repo mozzieongit/second-test
Filtered by oldest="7 days ago" and newest="2 days ago"

Repository: mozzieongit/second-test

- This is a verry important issue (#1)
    by @secondary-affair at 2025-11-06T15:46:46Z
    at https://github.com/mozzieongit/second-test/issues/1

Repository: mozzieongit/test-repo

- Test issue about stuff (#5)
    by @secondary-affair at 2025-11-05T14:57:10Z
    at https://github.com/mozzieongit/test-repo/issues/5
- Another issue (#6)
    by @secondary-affair at 2025-11-05T15:13:49Z
    at https://github.com/mozzieongit/test-repo/issues/6
```
