#!/bin/zsh
# Gives every "assets/…" link in the site's pages a ?v= stamp taken from that file's contents, so a browser
# always fetches a page's stylesheet, script and pictures as a matching set. GitHub Pages lets browsers keep each
# file for 10 minutes, so without this a reload just after publishing can pair the new page with an old stylesheet.
# Run it after changing anything in docs/assets/, before committing:
#   scripts/site/stamp-assets.sh
set -e
cd "${0:A:h}/../../docs"
for page in *.html; do
  perl -pi -e '
    s{"assets/([^"?]+)(?:\?v=[0-9a-f]*)?"}{
      my $f = "assets/$1";
      if (-f $f) { my $h = `shasum -a 256 "$f"`; "\"$f?v=" . substr($h, 0, 8) . "\"" } else { warn "missing $f\n"; "\"$f\"" }
    }ge' "$page"
  echo "$page: $(grep -o '"assets/[^"]*?v=[0-9a-f]*"' "$page" | wc -l | tr -d ' ') links stamped"
done
