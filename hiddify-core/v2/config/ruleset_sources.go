package config

import (
	"fmt"
	"strings"
	"time"

	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json/badoption"
)

const ruleSetUpdateInterval = badoption.Duration(5 * 24 * time.Hour)

// RuleSetSource declares source metadata for remote rule-set creation.
// Stage 2B-1 note: fallback URLs are metadata only for future downloader/cache work.
// Runtime still uses PrimaryURL only.
type RuleSetSource struct {
	Tag            string
	PrimaryURL     string
	FallbackURLs   []string
	Format         string
	UpdateInterval badoption.Duration
	DownloadDetour string
}

func buildCountryGeositeRuleSetSource(region string) RuleSetSource {
	normalized := strings.ToLower(strings.TrimSpace(region))
	src := RuleSetSource{
		Tag:            "geosite-" + normalized,
		PrimaryURL:     fmt.Sprintf("https://raw.githubusercontent.com/hiddify/hiddify-geo/rule-set/country/geosite-%s.srs", normalized),
		FallbackURLs:   nil,
		Format:         C.RuleSetFormatBinary,
		UpdateInterval: ruleSetUpdateInterval,
		DownloadDetour: OutboundSelectTag,
	}
	// Stage 2B-1 compatibility probe result:
	// SagerNet/sing-geosite currently exposes geosite.db release artifacts.
	// A direct geosite-ru.srs URL is not confirmed, so no active .srs fallback is set here.
	return src
}

func buildCountryGeoIPRuleSetSource(region string) RuleSetSource {
	normalized := strings.ToLower(strings.TrimSpace(region))
	src := RuleSetSource{
		Tag:            "geoip-" + normalized,
		PrimaryURL:     fmt.Sprintf("https://raw.githubusercontent.com/hiddify/hiddify-geo/rule-set/country/geoip-%s.srs", normalized),
		FallbackURLs:   nil,
		Format:         C.RuleSetFormatBinary,
		UpdateInterval: ruleSetUpdateInterval,
		DownloadDetour: OutboundSelectTag,
	}
	// Stage 2B-1 metadata candidate (not active at runtime):
	// https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/country/geoip-<region>.srs
	// Keep disabled until Stage 2B-2 downloader/cache manager with compatibility validation.
	if normalized == "ru" {
		src.FallbackURLs = []string{
			"https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/country/geoip-ru.srs",
		}
	}
	return src
}

func buildBlockRuleSetSource(name string) RuleSetSource {
	return RuleSetSource{
		Tag:            name,
		PrimaryURL:     fmt.Sprintf("https://raw.githubusercontent.com/hiddify/hiddify-geo/rule-set/block/%s.srs", name),
		FallbackURLs:   nil,
		Format:         C.RuleSetFormatBinary,
		UpdateInterval: ruleSetUpdateInterval,
		DownloadDetour: OutboundSelectTag,
	}
}

func toRemoteRuleSet(source RuleSetSource) option.RuleSet {
	return option.RuleSet{
		Type:   C.RuleSetTypeRemote,
		Tag:    source.Tag,
		Format: source.Format,
		RemoteOptions: option.RemoteRuleSet{
			URL:            source.PrimaryURL,
			UpdateInterval: source.UpdateInterval,
			DownloadDetour: source.DownloadDetour,
		},
	}
}
