# The harness's own pull requests and publishing, with the recipes every
# repository has (README: "Pull requests from a laptop", "Maintaining the
# harness"):
#   just merge [TITLE]   a pull request from this feature branch, merged once
#                        the self-test is green; it publishes nothing
#   just release-patch   publishes main: the next v1.x.y on its merge commit,
#                        and v1 moved there (-minor; -major starts v2)

# Show the recipes
default:
    @just --list

# scripts/pr.sh merge, with `-`: the harness has no version file.

# A pull request into main from this feature branch, merged once the self-test is green
[positional-arguments]
merge TITLE="":
    bash scripts/pr.sh merge - "$1"

# Publish main: v1.x.y on the merge commit, and v1 moved there
release-patch:
    bash scripts/publish.sh patch

# Publish main: v1.x.0 (new inputs or behaviour callers can use), v1 moved
release-minor:
    bash scripts/publish.sh minor

# A breaking change: v2.0.0 and a new v2; v1 stays until every caller says @v2
release-major:
    bash scripts/publish.sh major
