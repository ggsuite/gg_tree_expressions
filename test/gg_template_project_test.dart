// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_template_project/gg_template_project.dart';
import 'package:test/test.dart';

void main() {
  group('GgTemplateProject()', () {
    group('foo()', () {
      test('should return foo', () async {
        const ggTemplateProject = GgTemplateProject();
        expect(ggTemplateProject.foo(), 'foo');
      });
    });
  });
}
