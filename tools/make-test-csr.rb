#!/opt/puppetlabs/puppet/bin/ruby
# frozen_string_literal: true

# Generate a certificate signing request with arbitrary extensions, for testing
# a master's autosign policy.
#
# Usage:
#   make-test-csr.rb <certname> <extensions-json> [challenge-password]
#
# Example -- a CSR claiming a tenant the estate does not have:
#   make-test-csr.rb rogue.lab.pfpt \
#     '{"pp_project":"evilcorp","pp_environment":"nonprod"}' \
#     amex-nonprod-join-2026
#
# Writes the PEM to stdout.
#
# WHY THIS EXISTS
# ---------------
# An autosign validator that only ever says yes is not a control, and the only
# way to know it says no is to hand it something it should refuse. Building the
# CSR with Puppet's own API rather than raw openssl matters: the extension
# request attribute is a nested SET OF SEQUENCE that is easy to get subtly
# wrong, and a malformed CSR would be refused for the wrong reason -- which
# would look like the policy working.
#
# It lives as a file rather than inline in provision.sh because the Ruby is
# three levels of quoting deep when embedded in `docker exec sh -c '...'`, and
# a quoting mistake there produces a refusal that also looks like success.

require 'json'
require 'puppet'

# Settings must be initialised with an EMPTY argv. Puppet.initialize_settings
# parses ARGV, and would choke on this script's own arguments.
Puppet.initialize_settings([])

require 'puppet/ssl/oids'
require 'puppet/ssl/certificate_request'

# Requiring oids.rb is NOT enough: registration is guarded behind an internal
# flag and only happens when this is called. Without it, generate() fails with
#   Cannot create CSR with extension request pp_project:
#     OBJ_txt2obj: unknown object name
Puppet::SSL::Oids.register_puppet_oids

certname = ARGV[0] or abort('usage: make-test-csr.rb <certname> <extensions-json> [challenge-password]')
extensions = JSON.parse(ARGV[1] || '{}')
challenge = ARGV[2]

# 2048 rather than 4096: this key is thrown away after one policy decision, and
# on an emulated arm64 container 4096 adds real seconds to every test case.
key = OpenSSL::PKey::RSA.new(2048)
csr = Puppet::SSL::CertificateRequest.new(certname)

options = { extension_requests: extensions }
# :csr_attributes carries CUSTOM attributes, which live only in the CSR and are
# never copied into the signed certificate -- which is exactly what makes
# challengePassword usable as a one-time provisioning secret.
options[:csr_attributes] = { 'challengePassword' => challenge } if challenge && !challenge.empty?

csr.generate(key, options)
puts csr.content.to_pem
