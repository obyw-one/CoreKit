//
//  Coordinator.swift
//  CoreKit
//
//  Extracted from WabiSabi — Created by Jeoffrey Thirot on 11/03/2024.
//
//  Coordinator Pattern — Navigation ownership via Combine signals.
//
//  ## Architecture
//
//  The Coordinator owns **all navigation** for its flow (pages, sheets, modals).
//  Views and ViewModels never manipulate navigation state directly — they send
//  signals through a Combine `PassthroughSubject`, and the Coordinator reacts.
//
//  ```
//  View / ViewModel
//      → coordinator.userAction.send(.someAction)        // signal
//          → BaseCoordinator.bindUserInteraction()        // Combine pipeline
//              → handleUser(action:)                      // routing
//                  → private navigation method             // state mutation
//                      → @Published sheet / currentPage    // SwiftUI reacts
//  ```
//
//  ## How to create a new Coordinator
//
//  1. Define scoped types (actions, pages, sheets) in a `<Name>CoordinatorableDI` struct:
//
//     ```swift
//     struct HomeCoordinatorableDI {
//         enum Action: Hashable { case showDetail(Todo), present }
//         enum Page: String, Identifiable, CaseIterable { case list, settings }
//         enum Sheet: String, Identifiable { case popup }
//     }
//     ```
//
//  2. Create the coordinator class, override `start()` and `handleUser(action:)`:
//
//     ```swift
//     final class HomeCoordinator: BaseCoordinator<Action, HomePresenter>,
//                                  ObservableObject {
//         @Published var sheet: Sheet?
//         @Published private(set) var currentPage: Page = .list
//
//         override func handleUser(action: Action) {
//             switch action {
//             case .showDetail(let todo): pushDetail(todo)
//             case .present:              sheet = .popup
//             }
//         }
//
//         override func start() -> HomePresenter { HomePresenter() }
//     }
//     ```
//
//  ## How to send actions
//
//  From a **View** or **ViewModel**, send a signal — never set navigation state:
//
//     ```swift
//     // From a View (coordinator available in environment or property)
//     coordinator.userAction.send(.showDetail(todo))
//
//     // From a ViewModel holding a weak coordinator reference
//     coordinator?.userAction.send(.loginSuccess)
//
//     // Child coordinator bubbling up to parent
//     appCoordinator.userAction.send(.loginCompleted)
//     ```
//
//  The signal goes through `bindUserInteraction()` (Combine, @MainActor)
//  → `handleUser(action:)` → private method → `@Published` state change
//  → SwiftUI re-renders.
//
//  ## Parent / Child hierarchy
//
//  Coordinators form a tree. `retrieveOrCreateCoordinator()` lazily instantiates
//  child coordinators and keeps them in `children`. The parent cleans up children
//  when switching pages (e.g., navigating away from onboarding removes the
//  OnboardingCoordinator from the children array).
//

import Combine
import os
import SwiftUI

@MainActor
public protocol Coordinator<UserAction, Presenter>: AnyObject, Identifiable, Equatable {
    associatedtype UserAction: Hashable

    var id: UUID { get }
    var parent: (any Coordinator)? { get set }
    var children: [any Coordinator] { get set }
    var userAction: PassthroughSubject<UserAction, Never> { get }

    init(parent: (any Coordinator)?)

    associatedtype Presenter: View
    @ViewBuilder
    func start() -> Presenter

    func handleUser(action: UserAction)
}

// MARK: - Method useful to Coordinator

public extension Coordinator {
    func retrieveOrCreateCoordinator<T: Coordinator>() -> T {
        guard let coordinator = children.last(where: { $0 is T }) else {
            let newCoordinator = T(parent: self)
            children.append(newCoordinator)
            return newCoordinator
        }

        return coordinator as! T
    }
}

// MARK: - Base implementation for `any Coordinator`

@MainActor
open class BaseCoordinator<U: Hashable, P: View>: Coordinator {
    public typealias UserAction = U
    public typealias Presenter = P

    // MARK: - Variables

    // Private variables

    private var cancellables = Set<AnyCancellable>()

    // Public variables

    public let id = UUID()

    public weak var parent: (any Coordinator)?
    public var children: [any Coordinator] = [] {
        didSet {
            AppLog.navigation.debug("Coordinator.children(\(DebugAddress.address(self))): \(self.children)")
        }
    }

    public let userAction = PassthroughSubject<U, Never>()

    // MARK: - Constructors

    /**
     Method to create an abstract coordinator and init the user interaction binding

     */
    public required init(parent: (any Coordinator)?) {
        self.parent = parent

        bindUserInteraction()
    }

    // MARK: - Public methods

    /**
     Method to create the start point to manage the navigation flow in SwiftUI View system

     - Returns: Specific View define by the `Presenter` typealias
     - Warning: This is an abstract methods, you need to override it on every child.

     */
    open func start() -> P {
        assertionFailure("Need to override this function to build the Presenter")
        return EmptyView() as! P
    }

    // MARK: - Private methods

    /**
     Method to bind user action via the `PassthroughSubject` named `userAction` and apply any signal to `handleUser(action:)`

     */
    private func bindUserInteraction() {
        userAction
            .sink { [weak self] action in
                guard let self else { return }

                self.handleUser(action: action)
            }
            .store(in: &cancellables)
    }

    // MARK: - Handle user actions

    /**
     Method to handle user action coming from views managed by this flow

     - Parameter action: UserAction event to specify the user interaction
     - Warning: This is an abstract methods, you need to override it on every child.

     */
    open func handleUser(action _: UserAction) {
        assertionFailure("Need to override this function to handle actions")
    }

    // MARK: - Equatable Conformance

    nonisolated public static func == (lhs: BaseCoordinator<U, P>, rhs: BaseCoordinator<U, P>) -> Bool {
        lhs.id == rhs.id
    }
}
