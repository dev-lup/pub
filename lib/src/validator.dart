// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import 'entrypoint.dart';
import 'log.dart' as log;
import 'package.dart';
import 'sdk.dart';
import 'system_cache.dart';
import 'validator/analyze.dart';
import 'validator/changelog.dart';
import 'validator/compiled_dartdoc.dart';
import 'validator/dependency.dart';
import 'validator/dependency_override.dart';
import 'validator/deprecated_fields.dart';
import 'validator/devtools_extension.dart';
import 'validator/directory.dart';
import 'validator/executable.dart';
import 'validator/file_case.dart';
import 'validator/flutter_constraint.dart';
import 'validator/flutter_plugin_format.dart';
import 'validator/git_status.dart';
import 'validator/gitignore.dart';
import 'validator/leak_detection.dart';
import 'validator/license.dart';
import 'validator/name.dart';
import 'validator/pubspec.dart';
import 'validator/pubspec_field.dart';
import 'validator/pubspec_typo.dart';
import 'validator/readme.dart';
import 'validator/relative_version_numbering.dart';
import 'validator/sdk_constraint.dart';
import 'validator/size.dart';
import 'validator/strict_dependencies.dart';

/// The base class for validators that check whether a package is fit for
/// uploading.
///
/// Each validator should override [errors], [warnings], or both to return
/// lists of errors or warnings to display to the user. Errors will cause the
/// package not to be uploaded; warnings will require the user to confirm the
/// upload.
abstract class Validator {
  /// The accumulated errors for this validator.
  ///
  /// Filled by calling [validate].
  final errors = <String>[];

  /// The accumulated warnings for this validator.
  ///
  /// Filled by calling [validate].
  final warnings = <String>[];

  /// The accumulated hints for this validator.
  ///
  /// Filled by calling [validate].
  final hints = <String>[];

  late ValidationContext context;
  Package get package => context.entrypoint.workPackage;
  SystemCache get cache => context.entrypoint.cache;
  int get packageSize => context.packageSize;
  Uri get serverUrl => context.serverUrl;
  List<String> get files => context.files;

  /// Validates the entrypoint, adding any errors and warnings to [errors] and
  /// [warnings], respectively.
  Future<void> validate();

  /// Adds an error if the package's SDK constraint doesn't exclude Dart SDK
  /// versions older than [firstSdkVersion].
  @protected
  void validateSdkConstraint(Version firstSdkVersion, String message) {
    // If the SDK constraint disallowed all versions before [firstSdkVersion],
    // no error is necessary.
    if (package.pubspec.dartSdkConstraint.originalConstraint
        .intersect(VersionRange(max: firstSdkVersion))
        .isEmpty) {
      return;
    }

    if (firstSdkVersion.isPreRelease &&
        !_isSamePreRelease(firstSdkVersion, sdk.version)) {
      // Unless the user is using a dev SDK themselves, suggest that they use a
      // non-dev SDK constraint, even if there were some dev versions that are
      // allowed.
      firstSdkVersion = firstSdkVersion.nextPatch;
    }

    final allowedSdks = VersionRange(
      min: firstSdkVersion,
      includeMin: true,
      max: firstSdkVersion.isPreRelease
          ? firstSdkVersion.nextPatch
          : firstSdkVersion.nextBreaking,
    );

    var newSdkConstraint = package.pubspec.dartSdkConstraint.originalConstraint
        .intersect(allowedSdks);
    if (newSdkConstraint.isEmpty) newSdkConstraint = allowedSdks;

    errors.add('$message\n'
        'Make sure your SDK constraint excludes old versions:\n'
        '\n'
        'environment:\n'
        '  sdk: "${newSdkConstraint.asCompatibleWithIfPossible()}"');
  }

  /// Returns whether [version1] and [version2] are pre-releases of the same
  /// version.
  bool _isSamePreRelease(Version version1, Version version2) =>
      version1.isPreRelease &&
      version2.isPreRelease &&
      version1.patch == version2.patch &&
      version1.minor == version2.minor &&
      version1.major == version2.major;

  /// Run all validators on the [entrypoint] package and print their results.
  ///
  /// [files] should be the result of `entrypoint.root.listFiles()`.
  ///
  /// When the future completes [hints] [warnings] amd [errors] will have been
  /// appended with the reported hints warnings and errors respectively.
  ///
  /// [packageSize], if passed, should complete to the size of the tarred
  /// package, in bytes. This is used to validate that it's not too big to
  /// upload to the server.
  static Future<void> runAll(
    Entrypoint entrypoint,
    int packageSize,
    Uri serverUrl,
    List<String> files, {
    required List<String> hints,
    required List<String> warnings,
    required List<String> errors,
  }) async {
    final validators = [
      FileCaseValidator(),
      AnalyzeValidator(),
      GitignoreValidator(),
      GitStatusValidator(),
      PubspecValidator(),
      LicenseValidator(),
      NameValidator(),
      PubspecFieldValidator(),
      DependencyValidator(),
      DependencyOverrideValidator(),
      DeprecatedFieldsValidator(),
      DirectoryValidator(),
      ExecutableValidator(),
      CompiledDartdocValidator(),
      ReadmeValidator(),
      ChangelogValidator(),
      SdkConstraintValidator(),
      StrictDependenciesValidator(),
      FlutterConstraintValidator(),
      FlutterPluginFormatValidator(),
      RelativeVersionNumberingValidator(),
      PubspecTypoValidator(),
      LeakDetectionValidator(),
      SizeValidator(),
      DevtoolsExtensionValidator(),
    ];

    final context = ValidationContext(
      entrypoint,
      packageSize,
      serverUrl,
      files,
    );
    return await Future.wait(
      validators.map((validator) async {
        validator.context = context;
        await validator.validate();
      }),
    ).then((_) {
      hints.addAll([for (final validator in validators) ...validator.hints]);
      warnings
          .addAll([for (final validator in validators) ...validator.warnings]);
      errors.addAll([for (final validator in validators) ...validator.errors]);

      String presentDiagnostics(List<String> diagnostics) => diagnostics
          .map((diagnostic) => "* ${diagnostic.split('\n').join('\n  ')}\n")
          .join('\n');
      final sections = <String>[];

      for (final (kind, diagnostics) in [
        ('error', errors),
        ('potential issue', warnings),
        ('hint', hints),
      ]) {
        if (diagnostics.isNotEmpty) {
          final s = diagnostics.length > 1 ? 's' : '';
          final count = diagnostics.length > 1 ? '${diagnostics.length} ' : '';
          sections.add(
            'Package validation found the following $count$kind$s:\n'
            '${presentDiagnostics(diagnostics)}',
          );
        }
      }
      log.message(sections.join('\n'));
    });
  }

  /// Returns the [files] that are [path] or inside [path] (relative to the
  /// package entrypoint).
  // TODO(sigurdm): Consider moving this to a more central location.
  List<String> filesBeneath(String path, {required bool recursive}) {
    final base = p.canonicalize(p.join(package.dir, path));
    return files
        .where(
          recursive
              ? (file) =>
                  p.isWithin(base, p.canonicalize(file)) ||
                  p.canonicalize(file) == base
              : (file) => p.canonicalize(p.dirname(file)) == base,
        )
        .toList();
  }
}

class ValidationContext {
  final Entrypoint entrypoint;
  final int packageSize;
  final Uri serverUrl;
  final List<String> files;

  ValidationContext(
    this.entrypoint,
    this.packageSize,
    this.serverUrl,
    this.files,
  );
}
