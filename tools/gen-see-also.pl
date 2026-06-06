#!/usr/bin/env perl
#
# Append a "See also" cross-link footer to each Book and Handbook chapter.
#
# The relationship map is authored by hand (it encodes how the chapters relate
# architecturally). The footer is regenerated idempotently: any existing
# "## See also" section at the end of a file is replaced. Run from the polyrepo
# root:  perl astrid-book/tools/gen-see-also.pl
#
use strict;
use warnings;

my $root = $ENV{ASTRID_SRC} // '.';

my %title = (
  'foundations/kernel-is-dumb'                 => 'The Kernel Is Dumb',
  'foundations/boot-sequence'                  => 'The Boot Sequence',
  'capsule-model/manifest-and-engines'         => 'The Capsule Manifest and Engines',
  'capsule-model/imports-exports-resolution'   => 'Imports, Exports, and Dependency Resolution',
  'capsule-model/lifecycle'                    => 'Capsule Lifecycle',
  'host-abi/the-syscall-surface'               => 'The Syscall Surface',
  'host-abi/packages-fs-io-storage'            => 'Packages: Filesystem, IO, and Storage',
  'host-abi/packages-ipc-net-http-sys-process' => 'Packages: IPC, Net, HTTP, Sys, Process',
  'host-abi/packages-approval-identity-uplink' => 'Packages: Approval, Identity, Uplink',
  'host-abi/capability-gating'                 => 'Capability Gating',
  'host-abi/abi-evolution'                     => 'ABI Evolution',
  'bus/topics-and-wildcards'                   => 'Topics and Wildcards',
  'bus/interceptors'                           => 'Interceptors',
  'bus/tools-as-ipc'                           => 'Tools as an IPC Convention',
  'bus/routing-and-backpressure'               => 'Per-Principal Routing and Backpressure',
  'security/five-layer-gate'                   => 'The Five-Layer Security Gate',
  'security/capabilities-and-tokens'           => 'Capabilities, Tokens, and Delegation',
  'security/policy-budget-approval-audit'      => 'Policy, Budget, Approval, and Audit',
  'security/os-process-sandbox'                => 'The OS Process Sandbox',
  'storage/vfs-overlay'                        => 'The VFS Copy-on-Write Overlay',
  'storage/kv'                                 => 'KV Storage',
  'storage/audit-chain'                        => 'The Cryptographic Audit Chain',
  'identity/principal-and-isolation'           => 'PrincipalId and Per-Invocation Isolation',
  'identity/profiles-groups-quotas'            => 'Profiles, Groups, and Quotas',
  'distribution/distros-and-store'             => 'Distros and the Content-Addressed Store',
  'distribution/build-pipeline'                => 'The Build Pipeline and WASM Targets',
  'evolution/rfc-process'                      => 'The RFC Process',
  'evolution/wit-contracts'                    => 'WIT Contracts and the Three-Repo Flow',
  'handbook/polyrepo-and-workflow'             => 'Working on Astrid: The Polyrepo and Git Workflow',
  'handbook/the-kernel-is-dumb-law'            => 'The Kernel-Is-Dumb Law',
  'handbook/rfc-trigger'                       => 'The RFC Trigger',
  'handbook/contribution-tiers'                => 'Contribution Tiers and Security-Critical Crates',
  'handbook/release-and-standards'             => 'Release Process and Coding Standards',
);

my %rel = (
  'foundations/kernel-is-dumb'                 => ['foundations/boot-sequence', 'bus/topics-and-wildcards', 'host-abi/the-syscall-surface'],
  'foundations/boot-sequence'                  => ['foundations/kernel-is-dumb', 'capsule-model/lifecycle', 'distribution/distros-and-store'],
  'capsule-model/manifest-and-engines'         => ['capsule-model/imports-exports-resolution', 'capsule-model/lifecycle', 'host-abi/capability-gating'],
  'capsule-model/imports-exports-resolution'   => ['capsule-model/manifest-and-engines', 'distribution/distros-and-store'],
  'capsule-model/lifecycle'                    => ['capsule-model/manifest-and-engines', 'host-abi/packages-approval-identity-uplink'],
  'host-abi/the-syscall-surface'               => ['host-abi/capability-gating', 'host-abi/abi-evolution', 'capsule-model/manifest-and-engines'],
  'host-abi/packages-fs-io-storage'            => ['host-abi/the-syscall-surface', 'storage/vfs-overlay', 'storage/kv'],
  'host-abi/packages-ipc-net-http-sys-process' => ['host-abi/the-syscall-surface', 'bus/topics-and-wildcards', 'security/os-process-sandbox'],
  'host-abi/packages-approval-identity-uplink' => ['host-abi/the-syscall-surface', 'security/five-layer-gate', 'identity/principal-and-isolation'],
  'host-abi/capability-gating'                 => ['security/capabilities-and-tokens', 'host-abi/the-syscall-surface', 'capsule-model/manifest-and-engines'],
  'host-abi/abi-evolution'                     => ['evolution/wit-contracts', 'evolution/rfc-process', 'host-abi/the-syscall-surface'],
  'bus/topics-and-wildcards'                   => ['bus/interceptors', 'bus/tools-as-ipc', 'bus/routing-and-backpressure'],
  'bus/interceptors'                           => ['bus/topics-and-wildcards', 'bus/tools-as-ipc', 'security/five-layer-gate'],
  'bus/tools-as-ipc'                           => ['bus/interceptors', 'bus/topics-and-wildcards'],
  'bus/routing-and-backpressure'               => ['bus/topics-and-wildcards', 'identity/principal-and-isolation'],
  'security/five-layer-gate'                   => ['security/capabilities-and-tokens', 'security/policy-budget-approval-audit', 'storage/audit-chain', 'security/os-process-sandbox'],
  'security/os-process-sandbox'                => ['security/five-layer-gate', 'host-abi/packages-ipc-net-http-sys-process', 'storage/vfs-overlay', 'host-abi/capability-gating'],
  'security/capabilities-and-tokens'           => ['security/five-layer-gate', 'host-abi/capability-gating', 'identity/profiles-groups-quotas'],
  'security/policy-budget-approval-audit'      => ['security/five-layer-gate', 'security/capabilities-and-tokens', 'storage/audit-chain'],
  'storage/vfs-overlay'                        => ['host-abi/packages-fs-io-storage', 'identity/principal-and-isolation', 'security/os-process-sandbox'],
  'storage/kv'                                 => ['host-abi/packages-fs-io-storage', 'identity/principal-and-isolation'],
  'storage/audit-chain'                        => ['security/five-layer-gate', 'security/capabilities-and-tokens'],
  'identity/principal-and-isolation'           => ['identity/profiles-groups-quotas', 'storage/kv', 'storage/vfs-overlay'],
  'identity/profiles-groups-quotas'            => ['identity/principal-and-isolation', 'security/capabilities-and-tokens'],
  'distribution/distros-and-store'             => ['distribution/build-pipeline', 'capsule-model/manifest-and-engines'],
  'distribution/build-pipeline'                => ['distribution/distros-and-store', 'host-abi/the-syscall-surface'],
  'evolution/rfc-process'                      => ['evolution/wit-contracts', 'host-abi/abi-evolution'],
  'evolution/wit-contracts'                    => ['evolution/rfc-process', 'host-abi/abi-evolution', 'host-abi/the-syscall-surface'],
  'handbook/polyrepo-and-workflow'             => ['handbook/the-kernel-is-dumb-law', 'handbook/rfc-trigger', 'handbook/contribution-tiers'],
  'handbook/the-kernel-is-dumb-law'            => ['handbook/rfc-trigger', 'handbook/polyrepo-and-workflow'],
  'handbook/rfc-trigger'                       => ['handbook/the-kernel-is-dumb-law', 'handbook/contribution-tiers'],
  'handbook/contribution-tiers'                => ['handbook/release-and-standards', 'handbook/rfc-trigger'],
  'handbook/release-and-standards'             => ['handbook/contribution-tiers'],
);

sub file_for {
  my ($slug) = @_;
  my $base = $slug =~ m{^handbook/} ? 'astrid-handbook' : 'astrid-book';
  return "$root/$base/src/$slug.md";
}

# Relative link from source slug to target slug (both one directory deep).
sub link_for {
  my ($from, $to) = @_;
  my ($fdir) = $from =~ m{^([^/]+)/};
  my ($tdir, $tname) = $to =~ m{^([^/]+)/(.+)$};
  return $fdir eq $tdir ? "$tname.md" : "../$tdir/$tname.md";
}

my $count = 0;
for my $slug (sort keys %rel) {
  my $path = file_for($slug);
  unless (-f $path) { warn "missing: $path\n"; next; }

  local $/;
  open my $in, '<', $path or die "open $path: $!";
  my $content = <$in>;
  close $in;

  # Idempotent: drop any existing trailing See also section.
  $content =~ s/\n+## See also\b.*\z//s;
  $content =~ s/\s+\z//;

  my @links;
  for my $to (@{ $rel{$slug} }) {
    my $t = $title{$to} or do { warn "no title for $to\n"; next; };
    push @links, "- [$t](" . link_for($slug, $to) . ")";
  }
  next unless @links;

  $content .= "\n\n## See also\n\n" . join("\n", @links) . "\n";

  open my $out, '>', $path or die "write $path: $!";
  print $out $content;
  close $out;
  $count++;
}
print "see-also footers written to $count chapters\n";
