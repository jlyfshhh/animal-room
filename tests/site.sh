#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
site="$root/site"

required_pages=(
  index.html
  bask/index.html
  shed/index.html
  haven/index.html
  demo/index.html
  support/index.html
  trust/index.html
)

for page in "${required_pages[@]}"; do
  file="$site/$page"
  [[ -f "$file" ]] || { echo "Missing public page: $page" >&2; exit 1; }
  grep -q 'Content-Security-Policy' "$file" || {
    echo "$page has no in-page Content Security Policy." >&2
    exit 1
  }
done

# Each indexable public page declares its preferred production URL so shared
# links and search results do not split between equivalent paths.
canonical_urls=(
  'index.html|https://animalroom.app/'
  'bask/index.html|https://animalroom.app/bask/'
  'shed/index.html|https://animalroom.app/shed/'
  'haven/index.html|https://animalroom.app/haven/'
  'demo/index.html|https://animalroom.app/demo/'
  'support/index.html|https://animalroom.app/support/'
  'trust/index.html|https://animalroom.app/trust/'
)
for entry in "${canonical_urls[@]}"; do
  page="${entry%%|*}"
  canonical="${entry#*|}"
  grep -qF "<link rel=\"canonical\" href=\"$canonical\">" "$site/$page" || {
    echo "$page is missing its production canonical URL." >&2
    exit 1
  }
done

# Every main public surface should provide the adoption, evidence, support, and
# real-room paths. This is deliberately textual: these are static pages, so the
# links are the behavior.
for page in index.html bask/index.html shed/index.html haven/index.html; do
  file="$site/$page"
  for target in '/demo/' '/trust/' '/support/' 'instagram.com/thebioactivekeeper'; do
    grep -qF "$target" "$file" || {
      echo "$page does not link to $target." >&2
      exit 1
    }
  done
done

# The demo is safe to explore: clearly fake, no form submission, third-party
# script, embedded site, persistence, or network client. Shared same-origin
# scripts provide only the site-wide theme and accessibility controls.
grep -qi 'fictional sample data' "$site/demo/index.html" || {
  echo "The demo is not clearly labelled as fictional sample data." >&2
  exit 1
}
if grep -Eqi '<iframe|<form|fetch\(|XMLHttpRequest|localStorage|sessionStorage' "$site/demo/index.html"; then
  echo "The demo gained an external, embedded, submitted, persisted, or networked behavior." >&2
  exit 1
fi
if grep -Eo '<script[^>]+src="[^"]+"' "$site/demo/index.html" | grep -Ev 'src="/assets/(theme-init|site)\.js"' >/dev/null; then
  echo "The demo loads a script outside the audited shared site assets." >&2
  exit 1
fi
grep -qF 'id="share-demo"' "$site/demo/index.html" || {
  echo "The demo is missing its privacy-safe keeper share action." >&2
  exit 1
}
grep -qF "navigator.share" "$site/demo/index.html" || {
  echo "The demo share action does not use the native share sheet." >&2
  exit 1
}

# Every public page uses the same locally hosted theme system. The only page
# permitted to retain inline JavaScript is the self-contained fake-data demo.
for page in index.html bask/index.html shed/index.html haven/index.html demo/index.html support/index.html trust/index.html; do
  file="$site/$page"
  grep -qF 'href="/assets/site.css"' "$file" || { echo "$page is missing the shared site styles." >&2; exit 1; }
  grep -qF 'src="/assets/theme-init.js"' "$file" || { echo "$page is missing the pre-paint theme initializer." >&2; exit 1; }
  grep -qF 'src="/assets/site.js"' "$file" || { echo "$page is missing the shared site behavior." >&2; exit 1; }
done

# Ko-fi has one explanatory public entry point. GitHub's FUNDING.yml can still
# expose its native sponsor button, but the website should not scatter direct
# donation links around unrelated workflows.
kofi_pages="$(grep -RIl 'ko-fi.com/jlyfshhh' "$site" || true)"
kofi_count="$(printf '%s\n' "$kofi_pages" | awk 'NF {count++} END {print count+0}')"
[[ "$kofi_count" -eq 1 && "$kofi_pages" == "$site/support/index.html" ]] || {
  printf 'Expected one website Ko-fi destination on support/index.html; found: %s\n' "${kofi_pages:-none}" >&2
  exit 1
}
[[ "$(grep -Fc 'href="https://ko-fi.com/jlyfshhh"' "$site/support/index.html")" -eq 1 ]] || {
  echo "The support page should expose exactly one canonical Ko-fi call to action." >&2
  exit 1
}
grep -qF '>Leave a tip on Ko-fi</a>' "$site/support/index.html" || {
  echo "The canonical Ko-fi call to action is not clearly labelled." >&2
  exit 1
}

if grep -Rqi 'Buy crickets' "$site"; then
  echo "An old donation label remains; use Support Animal Room consistently." >&2
  exit 1
fi

for target in / /demo/ /bask/ /shed/ /haven/ /trust/ /support/; do
  grep -qF "https://animalroom.app${target}" "$site/sitemap.xml" || {
    echo "Sitemap is missing $target." >&2
    exit 1
  }
done
grep -qF 'https://animalroom.app/sitemap.xml' "$site/robots.txt" || {
  echo "robots.txt does not advertise the sitemap." >&2
  exit 1
}

# Viv is intentionally on hold and should not appear in the public product
# family, navigation, sitemap, or social assets until that decision changes.
[[ ! -e "$site/viv" ]] || {
  echo "The paused Viv product still has a public site directory." >&2
  exit 1
}
if grep -RqiE --exclude='*.png' --exclude='*.jpg' '(^|[^[:alnum:]])viv([^[:alnum:]]|$)' "$site"; then
  echo "The paused Viv product is still mentioned on the public site." >&2
  exit 1
fi

story="$root/.github/ISSUE_TEMPLATE/setup-story.yml"
[[ -f "$story" ]] || { echo "The setup-story issue form is missing." >&2; exit 1; }
grep -qF 'No — keep it in this public issue only' "$story" || {
  echo "The setup-story form does not default to an explicit no-reuse option." >&2
  exit 1
}
grep -qF 'this GitHub issue is public' "$story" || {
  echo "The setup-story form does not warn that submissions are public." >&2
  exit 1
}

echo "Public site tests passed."
