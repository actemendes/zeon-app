# UI Naming Checklist

Last updated: 2026-04-25

## Purpose

Single source of truth for UI naming in interfaces:
- fast navigation in codebase
- stable ids for QA/autotests
- shared naming language between frontend/backend/QA

Source registry: `lib/core/ui/ui_names.dart`

## Naming Convention

- `screen_*` -> page root
- `dialog_*` -> modal root
- `input_*` -> editable input fields
- `button_*` -> action buttons
- `tap_*` -> tappable containers (non-button)
- `panel_*` -> informative/action blocks
- `text_*` -> key display text values

## Screen Catalog (All interface pages)

| UI ID | File |
|---|---|
| `screen_about` | `lib/features/about/widget/about_page.dart` |
| `screen_home` | `lib/features/home/widget/home_page.dart` |
| `screen_intro` | `lib/features/intro/widget/intro_page.dart` |
| `screen_logs` | `lib/features/log/overview/logs_page.dart` |
| `screen_per_app_proxy` | `lib/features/per_app_proxy/overview/per_app_proxy_page.dart` |
| `screen_profile_details` | `lib/features/profile/details/profile_details_page.dart` |
| `screen_profile_link_account` | `lib/features/profile/overview/profile_link_account_page.dart` |
| `screen_profile_menu` | `lib/features/profile/overview/profile_menu_page.dart` |
| `screen_profile_payment` | `lib/features/profile/overview/profile_payment_page.dart` |
| `screen_profiles` | `lib/features/profile/overview/profiles_page.dart` |
| `screen_proxies_overview` | `lib/features/proxy/overview/proxies_overview_page.dart` |
| `screen_android_apps` | `lib/features/route_rules/overview/android_apps_page.dart` |
| `screen_generic_list` | `lib/features/route_rules/overview/generic_list_page.dart` |
| `screen_rule` | `lib/features/route_rules/overview/rule_page.dart` |
| `screen_rules` | `lib/features/route_rules/overview/rules_page.dart` |
| `screen_dns_options` | `lib/features/settings/overview/sections/dns_options_page.dart` |
| `screen_general_options` | `lib/features/settings/overview/sections/general_page.dart` |
| `screen_inbound_options` | `lib/features/settings/overview/sections/inbound_options_page.dart` |
| `screen_route_options` | `lib/features/settings/overview/sections/route_options_page.dart` |
| `screen_tls_tricks` | `lib/features/settings/overview/sections/tls_tricks_page.dart` |
| `screen_warp_options` | `lib/features/settings/overview/sections/warp_options_page.dart` |
| `screen_settings` | `lib/features/settings/overview/settings_page.dart` |
| `screen_site_routing` | `lib/features/site_routing/overview/site_routing_page.dart` |

## Implemented Control IDs

### Intro and bind modal

| UI ID | File | Element |
|---|---|---|
| `image_intro_logo` | `lib/features/intro/widget/intro_page.dart` | Intro logo image |
| `button_intro_start` | `lib/features/intro/widget/intro_page.dart` | Start CTA |
| `button_intro_already_have_account` | `lib/features/intro/widget/intro_page.dart` | Open bind modal |
| `text_intro_terms_and_policy` | `lib/features/intro/widget/intro_page.dart` | Terms and policy text block |
| `dialog_intro_bind_account` | `lib/features/intro/widget/intro_page.dart` | Bind modal container |
| `text_intro_bind_description` | `lib/features/intro/widget/intro_page.dart` | Bind dialog helper text |
| `text_intro_bind_link_label` | `lib/features/intro/widget/intro_page.dart` | Bind dialog input label |
| `input_intro_bind_link` | `lib/features/intro/widget/intro_page.dart` | Link input field |
| `button_intro_bind_submit` | `lib/features/intro/widget/intro_page.dart` | Confirm bind action |

### Profile link account page

| UI ID | File | Element |
|---|---|---|
| `screen_profile_link_account` | `lib/features/profile/overview/profile_link_account_page.dart` | Page scaffold/root |
| `text_profile_link_hint` | `lib/features/profile/overview/profile_link_account_page.dart` | Top hint text |
| `panel_profile_link_account` | `lib/features/profile/overview/profile_link_account_page.dart` | Link panel container |
| `text_profile_link_label` | `lib/features/profile/overview/profile_link_account_page.dart` | Link label text |
| `text_profile_link_value` | `lib/features/profile/overview/profile_link_account_page.dart` | Selectable link text |
| `button_profile_link_copy` | `lib/features/profile/overview/profile_link_account_page.dart` | Copy link button |
| `button_profile_link_change_account` | `lib/features/profile/overview/profile_link_account_page.dart` | Change account button |

### Active proxy IP widgets

| UI ID | File | Element |
|---|---|---|
| `tap_proxy_ip_toggle` | `lib/features/proxy/active/ip_widget.dart` | Toggle hidden/visible IP |
| `text_proxy_ip_visible` | `lib/features/proxy/active/ip_widget.dart` | Visible IP text |
| `text_proxy_ip_hidden` | `lib/features/proxy/active/ip_widget.dart` | Masked IP text |
| `tap_proxy_unknown_ip` | `lib/features/proxy/active/ip_widget.dart` | Tap area for unknown IP |
| `text_proxy_unknown_ip` | `lib/features/proxy/active/ip_widget.dart` | Unknown IP text |
| `tap_proxy_ip_country_flag` | `lib/features/proxy/active/ip_widget.dart` | Country flag tap area |

## Verification Checklist

- [x] Central registry created (`UiNames`)
- [x] All page-level interface IDs registered
- [x] All page roots (`*page.dart`) now have explicit `screen_*` keys
- [x] Intro bind flow controls have explicit IDs
- [x] Profile link account controls have explicit IDs
- [x] Active IP widget interactions have explicit IDs
- [x] Text and display elements for the updated flows have explicit IDs
- [ ] Expand explicit `key` coverage to all modal dialogs and shared components
