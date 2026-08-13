//go:build !zeon_ru_remote_dns_baseline

package config

// ruRemoteDNSBaseline is false for the intended Stage 2.8 policy. The
// validation-only baseline build flips only this DNS choice via its build tag.
const ruRemoteDNSBaseline = false
