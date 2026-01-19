# Copilot Instructions for fun-with-function

This repository provides examples on how to use Azure Integration Services, particularly Azure Functions. When contributing to this repository, please follow these guidelines:

## About This Repository

This is an educational repository demonstrating:
- Azure Functions examples and patterns
- Azure Integration Services usage (API Management, Service Bus, Event Grid, Logic Apps)
- Serverless compute patterns
- Event-driven architectures

## Code Standards

### Language and Framework
- Primary language: Follow Azure Functions best practices for your chosen runtime (Node.js, C#, Python, etc.)
- Use TypeScript for Node.js functions when possible for better type safety
- Follow language-specific conventions (e.g., PEP 8 for Python, ESLint standards for JavaScript/TypeScript)

### Azure Functions Conventions
- Each function should have a clear, single responsibility
- Use appropriate trigger types (HTTP, Timer, Blob, Queue, Event Grid, etc.)
- Include proper error handling and logging
- Use Application Insights for monitoring when applicable
- Follow Azure Functions naming conventions (e.g., camelCase for JavaScript, PascalCase for C#)

### Code Quality
- Write clean, readable, and maintainable code
- Include meaningful comments for complex logic
- Use descriptive variable and function names
- Handle errors gracefully with appropriate error messages
- Implement proper input validation for HTTP triggers

## Development Workflow

### Testing
- Write unit tests for business logic
- Include integration tests for Azure service interactions when applicable
- Test functions locally using Azure Functions Core Tools before deployment
- Validate that examples work as documented

### Documentation
- Each example should include a clear README explaining:
  - What the function does
  - Required Azure resources
  - Configuration steps
  - How to run the example
- Update the main README.md when adding new examples
- Include inline comments for non-obvious code

### Project Structure
- Organize examples by integration service type or use case
- Keep function code and configuration together
- Use consistent folder structure across examples
- Include necessary configuration files (function.json, host.json, local.settings.json templates)

## Key Guidelines

1. **Simplicity**: Examples should be easy to understand and follow
2. **Best Practices**: Demonstrate proper Azure Functions patterns
3. **Security**: Never commit secrets, connection strings, or API keys
4. **Dependencies**: Keep dependencies minimal and up-to-date
5. **Completeness**: Examples should be runnable with minimal setup
6. **Educational Value**: Code should teach good practices to users

## Azure-Specific Considerations

- Use managed identities when possible instead of connection strings
- Follow the principle of least privilege for permissions
- Use environment variables for configuration
- Include proper resource cleanup in examples
- Consider cost implications of services used in examples
