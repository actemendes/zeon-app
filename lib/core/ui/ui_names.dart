/// Centralized UI identifiers for widget keys and test automation.
///
/// Naming convention:
/// - `screen_*` for page roots
/// - `dialog_*` for modal roots
/// - `input_*` for editable fields
/// - `button_*` for actionable buttons
/// - `tap_*` for tappable containers that are not explicit buttons
abstract final class UiNames {
  UiNames._();

  // Screens (*page.dart)
  static const screenAbout = 'screen_about';
  static const screenHome = 'screen_home';
  static const screenIntro = 'screen_intro';
  static const screenLogs = 'screen_logs';
  static const screenPerAppProxy = 'screen_per_app_proxy';
  static const screenProfileDetails = 'screen_profile_details';
  static const screenProfileLinkAccount = 'screen_profile_link_account';
  static const screenProfileMenu = 'screen_profile_menu';
  static const screenProfilePayment = 'screen_profile_payment';
  static const screenProfiles = 'screen_profiles';
  static const screenProxiesOverview = 'screen_proxies_overview';
  static const screenAndroidApps = 'screen_android_apps';
  static const screenGenericList = 'screen_generic_list';
  static const screenRule = 'screen_rule';
  static const screenRules = 'screen_rules';
  static const screenDnsOptions = 'screen_dns_options';
  static const screenGeneralOptions = 'screen_general_options';
  static const screenInboundOptions = 'screen_inbound_options';
  static const screenRouteOptions = 'screen_route_options';
  static const screenTlsTricks = 'screen_tls_tricks';
  static const screenWarpOptions = 'screen_warp_options';
  static const screenSettings = 'screen_settings';
  static const screenSiteRouting = 'screen_site_routing';

  // Intro + bind modal
  static const imageIntroLogo = 'image_intro_logo';
  static const textIntroTermsAndPolicy = 'text_intro_terms_and_policy';
  static const buttonIntroStart = 'button_intro_start';
  static const buttonIntroAlreadyHaveAccount = 'button_intro_already_have_account';
  static const dialogIntroBindAccount = 'dialog_intro_bind_account';
  static const textIntroBindDescription = 'text_intro_bind_description';
  static const textIntroBindLinkLabel = 'text_intro_bind_link_label';
  static const inputIntroBindLink = 'input_intro_bind_link';
  static const buttonIntroBindSubmit = 'button_intro_bind_submit';

  // Profile link account
  static const textProfileLinkHint = 'text_profile_link_hint';
  static const textProfileLinkLabel = 'text_profile_link_label';
  static const panelProfileLinkAccount = 'panel_profile_link_account';
  static const textProfileLinkValue = 'text_profile_link_value';
  static const buttonProfileLinkCopy = 'button_profile_link_copy';
  static const buttonProfileLinkChangeAccount = 'button_profile_link_change_account';

  // Active proxy IP widgets
  static const textProxyIpVisible = 'text_proxy_ip_visible';
  static const textProxyIpHidden = 'text_proxy_ip_hidden';
  static const tapProxyIpToggle = 'tap_proxy_ip_toggle';
  static const textProxyUnknownIp = 'text_proxy_unknown_ip';
  static const tapProxyUnknownIp = 'tap_proxy_unknown_ip';
  static const tapProxyIpCountryFlag = 'tap_proxy_ip_country_flag';
}
