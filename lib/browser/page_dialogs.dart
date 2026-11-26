import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:permission_handler/permission_handler.dart';

import '../l10n.dart';

/// Dialogs a web page can ask for: alert / confirm / prompt, a site wanting the
/// camera, microphone or location, and a login for a protected page.
/// Without these a page's own pop-ups are silently ignored.

Future<bool?> _ask(BuildContext context, String host, String message,
    {String ok = 'OK', String? cancel = 'Cancel'}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: host.isEmpty ? null : Text(host, style: const TextStyle(fontSize: 15)),
      content: SingleChildScrollView(child: Text(message)),
      actions: [
        if (cancel != null)
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: Text(tr(cancel))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr(ok))),
      ],
    ),
  );
}

Future<JsAlertResponse> pageAlert(BuildContext context, JsAlertRequest r) async {
  await _ask(context, r.url?.host ?? '', r.message ?? '', cancel: null);
  return JsAlertResponse(handledByClient: true, action: JsAlertResponseAction.CONFIRM);
}

Future<JsConfirmResponse> pageConfirm(
    BuildContext context, JsConfirmRequest r) async {
  final yes = await _ask(context, r.url?.host ?? '', r.message ?? '');
  return JsConfirmResponse(
      handledByClient: true,
      action: yes == true
          ? JsConfirmResponseAction.CONFIRM
          : JsConfirmResponseAction.CANCEL);
}

Future<JsPromptResponse> pagePrompt(
    BuildContext context, JsPromptRequest r) async {
  final ctrl = TextEditingController(text: r.defaultValue ?? '');
  final yes = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(r.message ?? '', style: const TextStyle(fontSize: 15)),
      content: TextField(controller: ctrl, autofocus: true),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('OK')),
      ],
    ),
  );
  final v = ctrl.text;
  ctrl.dispose();
  return JsPromptResponse(
      handledByClient: true,
      value: v,
      action: yes == true
          ? JsPromptResponseAction.CONFIRM
          : JsPromptResponseAction.CANCEL);
}

/// Camera / microphone for the page (video calls, voice recorders, QR scanners).
Future<PermissionResponse> pagePermission(
    BuildContext context, PermissionRequest r) async {
  final host = r.origin.host;
  final wantsCam = r.resources.contains(PermissionResourceType.CAMERA);
  final wantsMic = r.resources.contains(PermissionResourceType.MICROPHONE);
  final cam = wantsCam;
  final what = cam && wantsMic
      ? 'This site wants to use your camera and microphone.'
      : (cam
          ? 'This site wants to use your camera.'
          : (wantsMic ? 'This site wants to use your microphone.' : ''));
  if (what.isEmpty) {
    return PermissionResponse(
        resources: r.resources, action: PermissionResponseAction.DENY);
  }
  final yes = await _ask(
      context, host, tr(what),
      ok: 'Allow', cancel: 'Block');
  if (yes != true) {
    return PermissionResponse(
        resources: r.resources, action: PermissionResponseAction.DENY);
  }
  try {
    if (cam) await Permission.camera.request();
    if (wantsMic) await Permission.microphone.request();
  } catch (_) {}
  return PermissionResponse(
      resources: r.resources, action: PermissionResponseAction.GRANT);
}

Future<GeolocationPermissionShowPromptResponse> pageLocation(
    BuildContext context, String origin) async {
  final host = Uri.tryParse(origin)?.host ?? origin;
  final yes = await _ask(
      context, host, tr('This site wants to know your location.'),
      ok: 'Allow', cancel: 'Block');
  if (yes == true) {
    try {
      await Permission.locationWhenInUse.request();
    } catch (_) {}
  }
  return GeolocationPermissionShowPromptResponse(
      origin: origin, allow: yes == true, retain: false);
}

Future<HttpAuthResponse> pageLogin(
    BuildContext context, URLAuthenticationChallenge c) async {
  final user = TextEditingController();
  final pass = TextEditingController();
  final yes = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(c.protectionSpace.host, style: const TextStyle(fontSize: 15)),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(
            controller: user,
            autofocus: true,
            decoration: InputDecoration(labelText: tr('Username'))),
        const SizedBox(height: 8),
        TextField(
            controller: pass,
            obscureText: true,
            decoration: InputDecoration(labelText: tr('Password'))),
      ]),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Sign in'))),
      ],
    ),
  );
  final u = user.text, p = pass.text;
  user.dispose();
  pass.dispose();
  return HttpAuthResponse(
      username: u,
      password: p,
      action: yes == true
          ? HttpAuthResponseAction.PROCEED
          : HttpAuthResponseAction.CANCEL);
}
