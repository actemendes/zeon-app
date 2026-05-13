package hcore

import (
	"context"
	"encoding/json"
	"fmt"
	"os"

	"github.com/hiddify/hiddify-core/v2/config"
	"github.com/hiddify/hiddify-core/v2/db"
	hcommon "github.com/hiddify/hiddify-core/v2/hcommon"
	hutils "github.com/hiddify/hiddify-core/v2/hutils"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/experimental/libbox"
	"github.com/sagernet/sing-box/option"
)

func BuildConfigJson(ctx context.Context, in *StartRequest) (string, error) {
	Log(LogLevel_DEBUG, LogType_CORE, "Stating Service ")

	parsedContent, err := BuildConfig(ctx, in)
	if err != nil {
		return "", err
	}
	res, err := parsedContent.MarshalJSONContext(ctx)
	return string(res), err
}

func BuildConfig(ctx context.Context, in *StartRequest) (*option.Options, error) {
	Log(LogLevel_DEBUG, LogType_CORE, "Building Config...")

	readOpt := &config.ReadOptions{Content: in.ConfigContent, Path: in.ConfigPath}
	if !in.EnableRawConfig {
		if static.HiddifyOptions != nil {
			Log(LogLevel_INFO, LogType_CORE, safeOptionsSummary("buildconfig input", static.HiddifyOptions))
		}
		// hcontent, err := json.MarshalIndent(static.HiddifyOptions, "", " ")
		// if err != nil {
		// 	return nil, err
		// }

		// Log(LogLevel_DEBUG, LogType_CORE, "Building config ", string(hcontent))
		// Log(LogLevel_DEBUG, LogType_CORE, "Building config ")
		return config.BuildConfig(ctx, static.HiddifyOptions, readOpt)
	}
	return config.ReadSingOptions(ctx, readOpt)

}

func (s *CoreService) Parse(ctx context.Context, in *ParseRequest) (*ParseResponse, error) {
	return Parse(libbox.FromContext(ctx, nil), in)
}

func Parse(ctx context.Context, in *ParseRequest) (*ParseResponse, error) {
	defer config.DeferPanicToError("parse", func(err error) {
		Log(LogLevel_FATAL, LogType_CONFIG, err.Error())
		StopAndAlert(MessageType_UNEXPECTED_ERROR, err.Error())
	})

	path := in.TempPath
	if path == "" {
		path = in.ConfigPath
	}

	config, err := config.ParseConfigBytes(ctx, &config.ReadOptions{Content: in.Content, Path: path}, true, static.HiddifyOptions, false)
	if err != nil {
		return &ParseResponse{
			ResponseCode: hcommon.ResponseCode_FAILED,
			Message:      err.Error(),
		}, err
	}
	if in.ConfigPath != "" {
		err = os.WriteFile(in.ConfigPath, config, 0o644)
		if err != nil {
			return &ParseResponse{
				ResponseCode: hcommon.ResponseCode_FAILED,
				Message:      err.Error(),
			}, err
		}
	}
	return &ParseResponse{
		ResponseCode: hcommon.ResponseCode_OK,
		Content:      string(config),
		Message:      "",
	}, err
}

func (s *CoreService) ChangeHiddifySettings(ctx context.Context, in *ChangeHiddifySettingsRequest) (*CoreInfoResponse, error) {
	return ChangeHiddifySettings(in, true)
}

func ChangeHiddifySettings(in *ChangeHiddifySettingsRequest, insert bool) (*CoreInfoResponse, error) {
	static.HiddifyOptions = config.DefaultHiddifyOptions()
	defer func() {
		switch static.HiddifyOptions.LogLevel {
		case "debug":
			static.logLevel = LogLevel_DEBUG
		case "info":
			static.logLevel = LogLevel_INFO
		case "warn":
			static.logLevel = LogLevel_WARNING
		case "error":
			static.logLevel = LogLevel_ERROR
		case "fatal":
			static.logLevel = LogLevel_FATAL
		case "trace":
			static.logLevel = LogLevel_TRACE
		default:
			static.logLevel = LogLevel_INFO
		}
		static.debug = static.debug || static.logLevel <= LogLevel_DEBUG
	}()

	if in.HiddifySettingsJson == "" {
		return &CoreInfoResponse{}, nil
	}
	if insert {
		settings := db.GetTable[hcommon.AppSettings]()
		settings.UpdateInsert(&hcommon.AppSettings{
			Id:    "HiddifySettingsJson",
			Value: in.HiddifySettingsJson,
		})
	}

	err := json.Unmarshal([]byte(in.HiddifySettingsJson), static.HiddifyOptions)
	if err != nil {
		return nil, err
	}
	Log(LogLevel_INFO, LogType_CORE, safeOptionsSummary("change settings parsed", static.HiddifyOptions))

	if static.HiddifyOptions.Warp.WireguardConfigStr != "" {
		err := json.Unmarshal([]byte(static.HiddifyOptions.Warp.WireguardConfigStr), &static.HiddifyOptions.Warp.WireguardConfig)
		if err != nil {
			return nil, err
		}
	}
	if static.HiddifyOptions.Warp2.WireguardConfigStr != "" {
		err := json.Unmarshal([]byte(static.HiddifyOptions.Warp2.WireguardConfigStr), &static.HiddifyOptions.Warp2.WireguardConfig)
		if err != nil {
			return nil, err
		}
	}
	return &CoreInfoResponse{}, nil
}

func safeOptionsSummary(prefix string, h *config.HiddifyOptions) string {
	if h == nil {
		return prefix + ": <nil>"
	}
	selectorInterrupt := "nil"
	if h.RouteOptions.SelectorInterrupt != nil {
		selectorInterrupt = fmt.Sprintf("%v", *h.RouteOptions.SelectorInterrupt)
	}
	return fmt.Sprintf(
		"%s: profile=%s mtu_mode=%s transport=%s iface_mtu=%d fragment_mode=%s profile_dns=%s selector_interrupt=%s selector_tolerance=%d selector_sticky=%v mtu=%d tun_stack=%s strict_route=%v critical_fallback=%v runtime_data_dir=%s",
		prefix,
		h.RouteOptions.NetworkProfile,
		h.RouteOptions.NetworkMTUMode,
		h.RouteOptions.NetworkTransportType,
		h.RouteOptions.NetworkInterfaceMTU,
		h.RouteOptions.FragmentMode,
		h.RouteOptions.ProfileDNSStrategy,
		selectorInterrupt,
		h.RouteOptions.SelectorTolerance,
		h.RouteOptions.SelectorUseSticky,
		h.MTU,
		h.TUNStack,
		h.StrictRoute,
		h.RouteOptions.CriticalDomainsFallbackEnabled,
		h.RuntimeDataDir,
	)
}

func (s *CoreService) GenerateConfig(ctx context.Context, in *GenerateConfigRequest) (*GenerateConfigResponse, error) {
	return GenerateConfig(libbox.FromContext(ctx, nil), in)
}

func GenerateConfig(ctx context.Context, in *GenerateConfigRequest) (*GenerateConfigResponse, error) {
	defer config.DeferPanicToError("generateConfig", func(err error) {
		Log(LogLevel_FATAL, LogType_CONFIG, err.Error())
		StopAndAlert(MessageType_UNEXPECTED_ERROR, err.Error())
	})
	if static.HiddifyOptions == nil {
		static.HiddifyOptions = config.DefaultHiddifyOptions()
	}
	config, err := config.ParseBuildConfigBytes(ctx, static.HiddifyOptions, &config.ReadOptions{Path: in.Path})
	if err != nil {
		return nil, err
	}

	return &GenerateConfigResponse{
		ConfigContent: string(config),
	}, nil
}

func removeTunnelIfNeeded(options *option.Options) (tuninb *option.TunInboundOptions) {
	if hutils.TunAllowed() {
		return nil
	}

	// Create a new slice to hold the remaining inbounds
	newInbounds := make([]option.Inbound, 0, len(options.Inbounds))

	for _, inb := range options.Inbounds {
		if inb.Type == C.TypeTun {
			if d, ok := inb.Options.(option.TunInboundOptions); ok {
				tuninb = &d
			}

		} else {
			newInbounds = append(newInbounds, inb)
		}
	}

	options.Inbounds = newInbounds
	return tuninb
}
