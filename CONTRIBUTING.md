# Contributor Covenant Code of Conduct

## Our Pledge

We as members, contributors, and leaders pledge to make participation in our
community a harassment-free experience for everyone, regardless of age, body
size, visible or invisible disability, ethnicity, sex characteristics, gender
identity and expression, level of experience, education, socio-economic status,
nationality, personal appearance, race, religion, or sexual identity
and orientation.

We pledge to act and interact in ways that contribute to an open, welcoming,
diverse, inclusive, and healthy community.

## Our Standards

Examples of behavior that contributes to a positive environment for our
community include:

* Demonstrating empathy and kindness toward other people
* Being respectful of differing opinions, viewpoints, and experiences
* Giving and gracefully accepting constructive feedback
* Accepting responsibility and apologizing to those affected by our mistakes,
  and learning from the experience
* Focusing on what is best not just for us as individuals, but for the
  overall community

## Contributing to CI OS

We welcome contributions from the community! Here's how you can help:

### Getting Started

1. **Fork the Repository**
   ```bash
   git clone https://github.com/your-username/ci-os.git
   cd ci-os
   ```

2. **Set Up Development Environment**
   ```bash
   # Install Cubic for Ubuntu customization
   sudo apt install cubic
   
   # Make scripts executable
   chmod +x scripts/*.sh configs/scripts/*.sh
   ```

3. **Create a Feature Branch**
   ```bash
   git checkout -b feature/your-feature-name
   ```

### Types of Contributions

#### 🐛 Bug Reports
- Use the GitHub issue template
- Include system information
- Provide reproduction steps
- Attach logs when relevant

#### 🚀 Feature Requests
- Check existing issues first
- Use the feature request template
- Explain the use case
- Consider implementation complexity

#### 📝 Documentation
- Fix typos and grammar
- Improve clarity and examples
- Add missing documentation
- Update outdated information

#### 💻 Code Contributions
- Follow existing code style
- Test your changes thoroughly
- Update documentation as needed
- Add tests for new features

### Development Guidelines

#### Package Selection
- Prioritize essential development tools
- Consider disk space impact
- Test package compatibility
- Document package decisions

#### Script Development
- Use bash best practices (`set -euo pipefail`)
- Add error handling
- Include progress indicators
- Test on clean systems

#### Branding and Assets
- Follow brand guidelines
- Use vector formats when possible
- Optimize file sizes
- Maintain visual consistency

### Testing Requirements

#### Local Testing
```bash
# Test scripts individually
./scripts/test-ci-os.sh

# Test in virtual machine
# Follow testing documentation
```

#### Cubic Project Testing
- Test customization scripts in chroot
- Verify package installations
- Check boot process
- Validate system functionality

### Submission Process

1. **Code Review Checklist**
   - [ ] Code follows project style
   - [ ] All tests pass
   - [ ] Documentation updated
   - [ ] No breaking changes (or documented)
   - [ ] Security considerations addressed

2. **Pull Request Template**
   - Clear description of changes
   - Link to related issues
   - Screenshots for UI changes
   - Testing performed

3. **Review Process**
   - Maintainer review required
   - Address feedback promptly
   - Keep discussions constructive
   - Squash commits before merge

### Project Structure Guidelines

```
ci-os/
├── assets/           # All visual assets and branding
├── configs/          # Configuration files for Cubic
├── cubic-project/    # Cubic workspace (not in VCS)
├── docs/            # Project documentation
├── iso/             # ISO storage (not in VCS)
└── scripts/         # Setup and utility scripts
```

### Coding Standards

#### Bash Scripts
```bash
#!/bin/bash
# Script description
set -euo pipefail

# Variables in UPPER_CASE
VARIABLE_NAME="value"

# Functions in lowercase
function_name() {
    local param="$1"
    # Function body
}
```

#### Documentation
- Use Markdown format
- Include code examples
- Provide context and rationale
- Keep README files updated

### Security Guidelines

- Never commit secrets or passwords
- Use secure defaults in configurations
- Regular security updates
- Follow Ubuntu security best practices

### Release Process

1. **Version Numbering**
   - Semantic versioning (MAJOR.MINOR.PATCH)
   - Ubuntu LTS alignment for major versions

2. **Release Checklist**
   - [ ] All tests pass
   - [ ] Documentation updated
   - [ ] Security scan completed
   - [ ] Performance benchmarks run
   - [ ] Community testing feedback

3. **Distribution**
   - Generate ISO checksums
   - Update release notes
   - Announce on community channels

### Getting Help

- **GitHub Discussions**: General questions and ideas
- **GitHub Issues**: Bug reports and feature requests
- **Documentation**: Check docs/ directory first

### Recognition

Contributors will be recognized in:
- CONTRIBUTORS.md file
- Release notes
- Project documentation

Thank you for contributing to CI OS! 🎉
