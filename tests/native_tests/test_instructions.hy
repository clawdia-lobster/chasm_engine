"""Tests for the instructions (templating) module.

Tests template loading, formatting, and Hy name mangling with templates.
Templates use Python .format() with snake_case placeholders.
Hy callers use kebab-case keywords which get mangled to snake_case.
"""

(import pytest)
(import pathlib [Path])

(import chasm_engine.instructions [find-templates
                                    find-template
                                    complete-template])


(defn test-find-template []
  "Test finding a template file by name."
  (let [path (find-template "place")]
    (assert (isinstance path Path))
    (assert (.exists path))
    (assert (= (. path name) "place.toml"))))

(defn test-find-template-not-found []
  "Test finding a non-existent template returns a Path."
  (let [path (find-template "nonexistent")]
    (assert (isinstance path Path))
    (assert (= (. path name) "nonexistent.toml"))
    (assert (not (.exists path)))))

(defn test-place-templates-exist []
  "Test that expected templates exist."
  (let [templates (find-templates)]
    (assert (in "place" templates))
    (assert (in "character" templates))
    (assert (in "narrative" templates))))


;; Tests for Hy name mangling with templates
;; -----------------------------------------------------------------

(defn test-template-kebab-to-snake-mangling []
  "Test kebab-case kwargs mangled to snake_case for template placeholders."
  ;; Template has snake_case placeholders: world, placename, destination
  ;; Hy uses kebab-case keywords which get mangled to snake_case
  (let [result (complete-template "place" "accessible"
                                  :world "Fantasy"
                                  :placename "Tavern"
                                  :destination "Market")]
    (assert (in "Tavern" result))
    (assert (in "Market" result))
    (assert (in "Fantasy" result))))

(defn test-character-template-mangling []
  "Test character template with name mangling."
  (let [result (complete-template "character" "system"
                                  :name "Testchar"
                                  :place "Tavern"
                                  :setting "A fantasy world")]
    (assert (in "Testchar" result))
    (assert (in "Tavern" result))
    (assert (in "A fantasy world" result))))

(defn test-place-description-template []
  "Test place description template with multi-word kwargs."
  ;; place_name has underscore in template, use :place-name in Hy
  ;; description template has: nearby, place_name, place, length
  (let [result (complete-template "place" "description"
                                  :nearby "Forest, Mountain"
                                  :place-name "Tavern"
                                  :place "A cozy inn"
                                  :length "short")]
    (assert (in "Tavern" result))
    (assert (in "cozy inn" result))
    (assert (in "Forest" result))))

(defn test-template-missing-key []
  "Test that missing kwargs raise KeyError."
  (with [(pytest.raises KeyError)]
    (complete-template "place" "accessible")))

(defn test-template-template-not-found []
  "Test that missing template file raises FileNotFoundError."
  ;; When template file does not exist, FileNotFoundError is raised
  (with [(pytest.raises FileNotFoundError)]
    (complete-template "nonexistent" "foo" :name "test")))


;; Tests for double-brace escaping in templates
;; -----------------------------------------------------------------

(defn test-json-template-braces []
  "Test templates with double braces produce single braces in output."
  ;; character.toml json template has double braces for JSON structure
  (let [result (complete-template "character" "json"
                                  :name "Alice")]
    ;; Should contain JSON structure with single braces
    (assert (in "{" result))
    (assert (in "}" result))
    ;; Should NOT contain double braces (they were escaped)
    (assert (not (in "{{" result)))
    (assert (not (in "}}" result)))
    ;; Should contain the name
    (assert (in "Alice" result))))
