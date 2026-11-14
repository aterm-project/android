/*
 * WEB-MULTI-VAULT-SWITCH-01 is a focused entry point into the shared profile
 * fixture. It reuses its disposable server, two enrolled browser profiles,
 * encrypted Host helpers, Vault selector and cleanup path.
 */

process.argv.push('--multi-vault-only');
require('./cross_profile_sync.cjs');
