// Copyright (c) 2025, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:http/http.dart' as http;
import 'package:json_rpc_2/json_rpc_2.dart';

/// Mix this in to add support for the `docs` tool.
base mixin DocsSupport on MCPServer, ToolsSupport {
  final _client = VertexAIClient(
    projectId: 'dash-docs-vector-search',
    appId: 'flutter-docs-search_1768239835690',
    // Generate this token using:
    // gcloud auth print-access-token
    token: '',
  );

  @override
  FutureOr<InitializeResult> initialize(InitializeRequest request) {
    registerTool(docsTool, _runDocsTool);
    return super.initialize(request);
  }

  Future<CallToolResult> _runDocsTool(CallToolRequest request) async {
    final query = request.arguments?['query'] as String?;
    if (query == null) {
      throw RpcException(
        -32602, // invalid params
        'Missing required argument: query',
      );
    }

    try {
      final result = await _client.answer(query: query);
      final response = VertexResponse.fromJson(result);
      return CallToolResult(
        content: [TextContent(text: response.toMarkdown())],
      );
    } catch (e) {
      return CallToolResult(
        content: [TextContent(text: 'Error querying docs: $e')],
        isError: true,
      );
    }
  }

  static final docsTool = Tool(
    name: 'docs',
    description: 'Queries Flutter and Dart documentation.',
    inputSchema: Schema.object(
      properties: {'query': Schema.string(description: 'The question to ask.')},
      required: ['query'],
      additionalProperties: false,
    ),
  );
}

class VertexAIClient {
  final String projectId;
  final String appId;
  final String token;
  final String location;
  final String collection;
  final String servingConfig;

  VertexAIClient({
    required this.projectId,
    required this.appId,
    required this.token,
    this.location = 'global',
    this.collection = 'default_collection',
    this.servingConfig = 'default_search',
  });

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };

  String get _baseUrl =>
      'https://discoveryengine.googleapis.com/v1/projects/'
      '$projectId/locations/$location/collections/$collection/engines/$appId';

  Future<Map<String, dynamic>> answer({
    required String query,
    bool disableRephrasing = false,
    List<String>? classificationTypes,
    int? maxReturnResults,
    String? filter,
    String? boostSpec, // Passing simple string/json for now
    String? orderBy,
    String? searchResultMode,
    bool ignoreAdversarial = false,
    bool ignoreNonAnswerSeeking = false,
    String? modelVersion,
    String? preamble,
    bool includeCitations = false,
    String? answerLanguageCode,
    bool returnGroundingSupport =
        false, // Not fully detailed in args but good to have
    bool fallbackToSearch = false, // inferred
  }) async {
    final url = Uri.parse('$_baseUrl/servingConfigs/$servingConfig:answer');

    final body = <String, dynamic>{
      'query': {'text': query},
    };

    // Query Understanding Spec
    final queryUnderstandingSpec = <String, dynamic>{};
    if (disableRephrasing) {
      queryUnderstandingSpec['queryRephraserSpec'] = {'disable': true};
    }
    if (classificationTypes != null && classificationTypes.isNotEmpty) {
      queryUnderstandingSpec['queryClassificationSpec'] = {
        'types': classificationTypes,
      };
    }
    if (queryUnderstandingSpec.isNotEmpty) {
      body['queryUnderstandingSpec'] = queryUnderstandingSpec;
    }

    // Search Spec
    final searchParams = <String, dynamic>{};
    if (maxReturnResults != null) {
      searchParams['maxReturnResults'] = maxReturnResults;
    }
    if (filter != null) searchParams['filter'] = filter;
    if (boostSpec != null) {
      // Assuming user passes valid JSON or modifying to handle object later
      // For CLI simplicity, maybe parse if string, or just don't support complex boost in v1
    }
    if (orderBy != null) searchParams['orderBy'] = orderBy;
    if (searchResultMode != null) {
      searchParams['searchResultMode'] = searchResultMode;
    }

    if (searchParams.isNotEmpty) {
      body['searchSpec'] = {'searchParams': searchParams};
    }

    // Answer Generation Spec
    final answerGenerationSpec = <String, dynamic>{};
    if (ignoreAdversarial) {
      answerGenerationSpec['ignoreAdversarialQuery'] = true;
    }
    if (ignoreNonAnswerSeeking) {
      answerGenerationSpec['ignoreNonAnswerSeekingQuery'] = true;
    }
    if (modelVersion != null) {
      answerGenerationSpec['modelSpec'] = {'modelVersion': modelVersion};
    }
    if (preamble != null) {
      answerGenerationSpec['promptSpec'] = {'preamble': preamble};
    }
    if (includeCitations) answerGenerationSpec['includeCitations'] = true;
    if (answerLanguageCode != null) {
      answerGenerationSpec['answerLanguageCode'] = answerLanguageCode;
    }

    if (answerGenerationSpec.isNotEmpty) {
      body['answerGenerationSpec'] = answerGenerationSpec;
    }

    // Make request
    final response = await http.post(
      url,
      headers: _headers,
      body: jsonEncode(body),
    );

    return _handleResponse(response);
  }

  Future<Map<String, dynamic>> createSession({
    required String userPseudoId,
  }) async {
    final url = Uri.parse('$_baseUrl/sessions');
    final body = {'userPseudoId': userPseudoId};

    final response = await http.post(
      url,
      headers: _headers,
      body: jsonEncode(body),
    );
    return _handleResponse(response);
  }

  Future<Map<String, dynamic>> answerInSession({
    required String sessionId,
    required String query,
  }) async {
    // The "answer in session" command actually uses the same endpoint as the stateless answer,
    // but passes the session ID in the body.
    final url = Uri.parse('$_baseUrl/servingConfigs/$servingConfig:answer');

    // Ensure sessionId is a full resource name
    var fullSessionId = sessionId;
    if (!sessionId.startsWith('projects/')) {
      fullSessionId =
          'projects/$projectId/locations/$location/collections'
          '/$collection/engines/$appId/sessions/$sessionId';
    }

    final body = {
      'query': {'text': query},
      'session': fullSessionId,
    };

    final response = await http.post(
      url,
      headers: _headers,
      body: jsonEncode(body),
    );

    return _handleResponse(response);
  }

  Future<Map<String, dynamic>> getSession({required String sessionId}) async {
    Uri url;
    if (sessionId.startsWith('projects/')) {
      url = Uri.parse('https://discoveryengine.googleapis.com/v1/$sessionId');
    } else {
      url = Uri.parse('$_baseUrl/sessions/$sessionId');
    }
    final response = await http.get(url, headers: _headers);
    return _handleResponse(response);
  }

  Map<String, dynamic> _handleResponse(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } else {
      throw http.ClientException(
        'Request failed with status: ${response.statusCode}.\nBody: ${response.body}',
        Uri.parse('status:${response.statusCode}'),
      );
    }
  }
}

class VertexResponse {
  final Answer? answer;
  final String? answerQueryToken;

  VertexResponse({this.answer, this.answerQueryToken});

  factory VertexResponse.fromJson(Map<String, dynamic> jsn) {
    return VertexResponse(
      answer: jsn['answer'] != null
          ? Answer.fromJson(jsn['answer'] as Map<String, dynamic>)
          : null,
      answerQueryToken: jsn['answerQueryToken'] as String?,
    );
  }

  String toMarkdown() {
    final buffer = StringBuffer();
    if (answer != null) {
      buffer.writeln(answer!.toMarkdown());
    }
    return buffer.toString();
  }
}

class Answer {
  final String? state;
  final String? answerText;
  final List<Step>? steps;

  Answer({this.state, this.answerText, this.steps});

  factory Answer.fromJson(Map<String, dynamic> jsn) {
    return Answer(
      state: jsn['state'] as String?,
      answerText: jsn['answerText'] as String?,
      steps: (jsn['steps'] as List?)
          ?.map((e) => Step.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  String toMarkdown() {
    final buffer = StringBuffer();
    if (answerText != null) {
      buffer.writeln(answerText);
      buffer.writeln();
    }

    final citations = _extractCitations();
    if (citations.isNotEmpty) {
      buffer.writeln('## Sources');
      for (final citation in citations) {
        buffer.writeln('- [${citation.title}](${citation.uri})');
      }
    }
    return buffer.toString();
  }

  List<SearchResult> _extractCitations() {
    final results = <SearchResult>[];
    if (steps != null) {
      for (final step in steps!) {
        if (step.actions != null) {
          for (final action in step.actions!) {
            if (action.observation?.searchResults != null) {
              results.addAll(action.observation!.searchResults!);
            }
          }
        }
      }
    }
    return results;
  }
}

class Step {
  final String? state;
  final String? description;
  final List<Action>? actions;

  Step({this.state, this.description, this.actions});

  factory Step.fromJson(Map<String, dynamic> jsn) {
    return Step(
      state: jsn['state'] as String?,
      description: jsn['description'] as String?,
      actions: (jsn['actions'] as List?)
          ?.map((e) => Action.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class Action {
  final Observation? observation;

  Action({this.observation});

  factory Action.fromJson(Map<String, dynamic> jsn) {
    return Action(
      observation: jsn['observation'] != null
          ? Observation.fromJson(jsn['observation'] as Map<String, dynamic>)
          : null,
    );
  }
}

class Observation {
  final List<SearchResult>? searchResults;

  Observation({this.searchResults});

  factory Observation.fromJson(Map<String, dynamic> jsn) {
    return Observation(
      searchResults: (jsn['searchResults'] as List?)
          ?.map((e) => SearchResult.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class SearchResult {
  final String? document;
  final String? uri;
  final String? title;

  SearchResult({this.document, this.uri, this.title});

  factory SearchResult.fromJson(Map<String, dynamic> jsn) {
    return SearchResult(
      document: jsn['document'] as String?,
      uri: jsn['uri'] as String?,
      title: jsn['title'] as String?,
    );
  }
}
