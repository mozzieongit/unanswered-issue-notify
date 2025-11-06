#!/usr/bin/env bash

set -e

check-cmd() {
  [[ -z "$*" ]] && exit 2
  error=false
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null; then
      echo "Need $1 installed"
      error=true
    fi
  done

  [[ "$error" == true ]] && exit 1 || true
}

check-cmd gh jq sendmail

# Defaults
ORG=NLnetLabs
REPO=NLnetLabs/cascade

OLDEST="7 days ago"
NEWEST="2 days ago"

TO=""
FROM="$USER@$HOSTNAME"
SUBJECT="Reminder about unanswered issues in <repository>"
SENDMAIL_ACCOUNT=default

# Argument parsing and help

SCRIPTNAME=$0

usage() {
  cat <<EOF
Usage: $SCRIPTNAME [OPTIONS] -t <recipient>

Notify the recipient via e-mail about unanswered GitHub issues, if they are older than '--until' and have no labels or assignees.

Options:
  -r, --repository    Specify the repository to check [default: $REPO]
  -t, --to            Specify the email address to send the reminder mail to
  -f, --from          Specify the email address to send the reminder mail from [default: $FROM]
      --subject       Specify the email subject for the reminder mail [default: $SUBJECT]
  -o, --org           Specify the GitHub organization to fetch the members list [default: $ORG]
  -s, --since         Specify how old issues should maximally be to be fetched and checked for comments [default: $OLDEST]
  -u, --until         Specify how old issues should be at least to be considered unanswered [default: $NEWEST]
  -a, --account       Specify the sendmail account to use [default: $SENDMAIL_ACCOUNT]
  -h, --help          Print this help text
EOF
}

eval set -- "$(getopt -n "$0" -o "hr:t:f:o:s:u:a:" -l "help,repository:,to:,from:,org:,since:,until:,subject:,account:" -- "$@")"

while [[ -n "$1" ]]; do
  case "$1" in
    -h|--help)
      usage && exit
      ;;
    -r|--repository)
      REPO=$2
      shift 2
      ;;
    -t|--to)
      TO=$2
      shift 2
      ;;
    -f|--from)
      FROM=$2
      shift 2
      ;;
    -o|--org)
      ORG=$2
      shift 2
      ;;
    -s|--since)
      OLDEST=$2
      shift 2
      ;;
    -u|--until)
      NEWEST=$2
      shift 2
      ;;
    --subject)
      SUBJECT=$2
      shift 2
      ;;
    -a|--account)
      SENDMAIL_ACCOUNT=$2
      shift 2
      ;;
    --)
      shift 1
      break
      ;;
    *) echo "Unknown option: $1" && usage && exit 1
  esac
done

if [[ -z "$TO" ]]; then
  echo "Missing option '-t'"
  usage
  exit 1
fi

SUBJECT="Reminder about unanswered issues in $REPO"

# Fetch current members of $ORG
MEMBERS=$(gh api --method GET -F per_page=100 "/orgs/${ORG}/members" | jq -r '[ .[] | .login ] | join("|")')

##
## Functions ##
##

function notify() {
  if [[ "$SENDMAIL_ACCOUNT" != default ]]; then
    sendmail -a "$SENDMAIL_ACCOUNT" -i -t
  else
    sendmail -i -t
  fi <<MAIL
To: ${TO}
From: ${FROM}
Subject: ${SUBJECT}

There are issues without answers from members of the specified org.

Org: $ORG
Repo: $REPO
Filtered by oldest="$OLDEST" and newest="$NEWEST"

$1

MAIL
}

prettify-issues() {
  [[ -z "$1" ]] && return 1
  <<<"$1" jq -r 'sort_by(.number) | .[] |
    "- "
    + .title
    + " (#"
    + (.number | tostring)
    + ")\n    by @"
    + .login
    + " at "
    + .created_at
    + "\n    at "
    + .html_url
    '
}

fetch-issues() {
  gh api --paginate --method GET -F per_page=100 "/repos/${REPO}/issues?state=open&since=$(date -d "$OLDEST" -Is)" | \
    jq "[
      .[] | select(
        ( # has labels, and assignee
          isempty(.labels | .[]) and
          isempty(.assignees | .[])
        ) and ( # is not authored by one of us
          .user.login | test(\"${MEMBERS}\") | not
        ) and ( # creation time is older than 2 days
          .created_at | fromdateiso8601 < $(date -d "$NEWEST" +%s)
        )
      ) | {
        title,
        html_url,
        number,
        login: .user.login,
        created_at,
        url,
        comments,
        comments_url
      }
    ]"
}

filter-out-answered-issues() {
  comment_urls=$(jq -r '.[] | select(.comments != 0) | .comments_url' <<<"$1")
  has_comments=()

  # Fetch comments of issue and check if it has comments by MEMBERS
  while read -r url; do
    [[ -z "$url" ]] && continue
    issue_url=$(gh api --method GET -F per_page=100 "${url}?since=$(date -d "$OLDEST" -Is)" | \
      jq -r "[ .[] | select(
          # is authored by one of us
          .user.login | test(\"${MEMBERS}\")
        ) | .issue_url ] | unique | .[]"
      )
    if [[ -n "$issue_url" ]]; then
      has_comments+=("$issue_url")
    fi
  done <<<"$comment_urls"

  issues_with_comments=$(IFS="|"; echo "${has_comments[*]}")

  # Filter out issues that have comments from MEMBERS
  if [[ -n "$issues_with_comments" ]]; then
    printf "%s" "$issues" | jq "[
        .[] | select(
          # does not have a comment from us
          .url | test(\"${issues_with_comments}\") | not
        )
      ]"
  else
    printf "%s" "$issues"
  fi

}

is-empty() {
  [[ -z "$1" ]] || [[ "$(jq '. == []' <<<"$1")" == true ]]
}

### MAIN ###

issues=$(fetch-issues)
issues=$(filter-out-answered-issues "$issues")

if ! is-empty "$issues"; then
  notify "$(prettify-issues "$issues")"
fi
