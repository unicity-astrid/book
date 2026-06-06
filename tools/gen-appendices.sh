#!/usr/bin/env bash
#
# Generate The Astrid Book appendices from the canonical source.
#
# These appendices are GENERATED, not hand-written. Do not edit the output
# files. Edit the source of truth (the Rust constants and the WIT files) and
# re-run this script.
#
# Run from the polyrepo root (the directory that contains core/, wit/,
# capsules/, and astrid-book/). Override the source root with ASTRID_SRC.
#
#   bash astrid-book/tools/gen-appendices.sh
#
set -euo pipefail
ROOT="${ASTRID_SRC:-$(pwd)}"
OUT="$ROOT/astrid-book/src/appendix"
mkdir -p "$OUT"

# Strip em-dashes (the source descriptions contain them; the book does not).
strip_emdash() { perl -i -pe 's/[ \t]*\xe2\x80\x94[ \t]*/, /g;' "$1"; }

# ---------------------------------------------------------------------------
# 1. Capability catalog  <-  core/crates/astrid-core/src/capability_grammar.rs
# ---------------------------------------------------------------------------
perl - "$ROOT/core/crates/astrid-core/src/capability_grammar.rs" > "$OUT/capability-catalog.md" <<'PERL'
use strict; use warnings;
local $/; my $src = <>;
my ($body) = $src =~ /pub const CAPABILITY_CATALOG[^=]*=\s*\{.*?&\[(.*?)\]\s*\};/s;
die "CAPABILITY_CATALOG not found\n" unless defined $body;

print "# Appendix: Capability Catalog\n\n";
print "Generated from `CAPABILITY_CATALOG` in `core/crates/astrid-core/src/capability_grammar.rs`, the single source of truth shared by the kernel drift tests and the gateway `/api/sys/capabilities` route. Do not hand-edit. Regenerate with `astrid-book/tools/gen-appendices.sh`.\n\n";
print "Scope `self` means the capability acts only on the caller's own principal. `global` means it can target any principal or system-wide state. Danger tiers, lowest to highest: Safe, Normal, Elevated, Extreme. Order matches the catalog, which is part of the stable wire contract.\n\n";
print "| Capability | Scope | Danger | Description |\n|---|---|---|---|\n";
my $n = 0;
while ($body =~ /CapabilityInfo\s*\{(.*?)\}/sg) {
  my $b = $1;
  my ($id)    = $b =~ /id:\s*"([^"]*)"/;
  my ($desc)  = $b =~ /description:\s*"([^"]*)"/;
  my ($scope) = $b =~ /scope:\s*(\w+)/;
  my ($dang)  = $b =~ /danger:\s*(\w+)/;
  next unless defined $id;
  $scope = (defined $scope && $scope eq 'Self_') ? 'self' : 'global';
  $desc //= '';
  $desc =~ s/\|/\\|/g;
  print "| `$id` | $scope | $dang | $desc |\n";
  $n++;
}
print "\n_$n capabilities._\n\n";

# Runtime exemption capabilities (separate from the management catalog above).
my @ex;
while ($src =~ /pub const (CAP_[A-Z_]+):\s*&str\s*=\s*"([^"]*)"/g) {
  push @ex, [$1, $2];
}
if (@ex) {
  print "## Runtime exemption capabilities\n\n";
  print "These are not management-API capabilities. They are operator-granted profile capabilities that lift a runtime ceiling (the per-invocation CPU epoch interrupt or the bind/uplink restriction). A capsule cannot self-grant them through its manifest.\n\n";
  print "| Constant | Capability string |\n|---|---|\n";
  print "| `$_->[0]` | `$_->[1]` |\n" for @ex;
  print "\n";
}
PERL
strip_emdash "$OUT/capability-catalog.md"
echo "wrote capability-catalog.md"

# ---------------------------------------------------------------------------
# 2. Host ABI error codes  <-  wit/host/*.wit  (variant error-code)
# ---------------------------------------------------------------------------
perl - "$ROOT"/wit/host/*.wit > "$OUT/error-codes.md" <<'PERL'
use strict; use warnings;
print "# Appendix: Host ABI Error Codes\n\n";
print "Generated from the `error-code` variants in `wit/host/*.wit`. Every fallible host function returns `result<_, error-code>`. The `unknown(string)` arm carries a host-formatted detail string and is the catch-all; the named arms let a capsule match a specific failure without parsing text.\n\n";
for my $f (sort @ARGV) {
  local $/; open my $fh, '<', $f or next; my $c = <$fh>; close $fh;
  next unless $c =~ /variant\s+error-code\s*\{(.*?)\n[ \t]*\}/s;
  my $blk = $1;
  (my $pkg = $f) =~ s{.*/}{}; $pkg =~ s/\.wit$//;
  my @arms;
  for my $line (split /\n/, $blk) {
    next if $line =~ /^\s*\/\//;
    if ($line =~ /^\s*([a-z][a-z0-9-]*)\s*(\([^)]*\))?\s*,/) {
      my $arm = $1; my $pl = $2 // '';
      push @arms, "`$arm$pl`";
    }
  }
  next unless @arms;
  print "## `$pkg`\n\n";
  print join(", ", @arms), "\n\n";
}
PERL
strip_emdash "$OUT/error-codes.md"
echo "wrote error-codes.md"

# ---------------------------------------------------------------------------
# 3. Topic registry  <-  capsule manifests + kernel topic constants
# ---------------------------------------------------------------------------
{
  echo "# Appendix: Topic Registry"
  echo
  echo "Generated from the versioned topic strings declared in capsule manifests (\`capsules/*/Capsule.toml\` publish and subscribe tables) and the kernel source. This lists the statically declared topics. Reply topics that capsules construct at runtime by appending a correlation id (for example \`...response.<corr_id>\`) are not enumerated here; see the chapter on the bus for the request and response convention."
  echo
  grep -rhoE '"[a-z][a-z0-9-]*\.v[0-9]+\.[a-z0-9._*-]+"' \
    "$ROOT"/capsules/*/Capsule.toml "$ROOT"/core/crates/astrid-kernel/src 2>/dev/null \
    | tr -d '"' \
    | sort -u \
    | grep -v '[.]$' \
    | awk -F. '{ ns=$1; if (ns!=prev){ printf "\n## `%s.*`\n\n", ns; prev=ns } printf "- `%s`\n", $0 }'
  echo
} > "$OUT/topic-registry.md"
echo "wrote topic-registry.md"

echo "done. appendices in $OUT"
