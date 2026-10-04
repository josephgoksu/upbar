# Release procedure

This procedure is for maintainers. It makes a signed and notarized release of Upbar.

## 1. One-time setup

You must have an Apple Developer Program membership. You must have the Account Holder role to make a Developer ID certificate.

> [!CAUTION]
> The certificate, its password and the API key are secrets. Do not commit them. Do not show them in a log.

### 1.1 Make the Developer ID certificate

1. Open Xcode.
2. Select **Xcode > Settings > Accounts**.
3. Select your Apple ID, then click **Manage Certificates**.
4. Click **+**, then select **Developer ID Application**.
5. Open the Keychain Access app.
6. In **My Certificates**, right-click **Developer ID Application: <your name>**.
7. Select **Export**. Save the file as `cert.p12`. Type a strong password.

### 1.2 Make the App Store Connect API key

1. Go to [App Store Connect > Users and Access > Integrations](https://appstoreconnect.apple.com/access/integrations/api).
2. Click **+** to make a team key. Select the **Developer** role.
3. Download the key file (`AuthKey_<KEY_ID>.p8`). You can download it one time only.
4. Write down the **Key ID** and the **Issuer ID**.

### 1.3 Add the secrets to GitHub

1. In Terminal, go to the repository directory.
2. Type each command, then push the Return key. Each command asks for the value or reads the file.

   ```sh
   base64 -i cert.p12 | gh secret set MACOS_CERT_P12
   gh secret set MACOS_CERT_PASSWORD
   base64 -i AuthKey_<KEY_ID>.p8 | gh secret set NOTARY_KEY_P8
   gh secret set NOTARY_KEY_ID
   gh secret set NOTARY_ISSUER
   ```

3. Delete `cert.p12` from your disk.
4. Keep the `.p8` file in a safe location, for example a password manager.

## 2. Make a release

1. Add a section for the new version to `CHANGELOG.md`. Move the lines from `Unreleased` into it.
2. Commit the change and push it to `main`.
3. Make a tag and push it:

   ```sh
   git tag -a v0.2.0 -m "Upbar 0.2.0"
   git push origin v0.2.0
   ```

Result: The release workflow does these steps:

1. It runs the tests.
2. It signs the app with the Developer ID certificate and the hardened runtime.
3. It sends the app to Apple for notarization and waits for the result.
4. It attaches the notarization ticket to the app.
5. It starts the app to make sure that it keeps running.
6. It makes sure that Gatekeeper accepts the app.
7. It publishes the release with `Upbar.zip` and `Upbar.zip.sha256`.

> [!NOTE]
> If the secrets are not set, the workflow makes an ad-hoc signed release. macOS then blocks the first start of a browser download.
