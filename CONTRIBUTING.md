# Contribution guide

Thank you for your help with Upbar. Read this guide before you start.

## 1. Rules

Upbar must stay small. Each change must obey these rules:

- Keep the app in `Sources/Upbar/`. Add a file only for a separate feature.
- Do not add dependencies.
- Do not add a setting if a good default value is possible.
- Do not increase the memory, CPU or network use.
- Use only SwiftUI and the macOS frameworks.

> [!NOTE]
> Before you start a large change, open an issue. Describe the problem and your solution. This prevents work that we cannot merge.

## 2. Prepare your Mac

1. Install Xcode 16 or later.
2. Fork the repository on GitHub.
3. Clone your fork:

   ```sh
   git clone https://github.com/<your-name>/upbar.git
   ```

4. Go to the project directory:

   ```sh
   cd upbar
   ```

## 3. Make a change

1. Make a branch:

   ```sh
   git switch -c my-change
   ```

2. Make your change.
3. Run the tests:

   ```sh
   swift test
   ```

4. Build and start the app:

   ```sh
   ./build.sh install
   ```

5. Do a check of your change in the app.
6. If your change adds logic, add a test in `Tests/UpbarTests/`.
7. If your change is visible to users, add a line to the `Unreleased` section of `CHANGELOG.md`.

## 4. Send a pull request

1. Commit your change. Write the commit message in the imperative mood. For example: `Add a timeout setting`.
2. Push the branch to your fork.
3. Open a pull request on GitHub.
4. Complete the pull request template.

Result: The CI workflow runs the tests and builds the app. A maintainer reviews the pull request.

## 5. Documentation

Write the documentation in ASD-STE100 Simplified Technical English:

- Write procedural sentences with a maximum of 20 words.
- Write descriptive sentences with a maximum of 25 words.
- Write one instruction in each step.
- Use the active voice.
- Use one word for one meaning.

## 6. Code of conduct

All contributors must obey the [code of conduct](CODE_OF_CONDUCT.md).
