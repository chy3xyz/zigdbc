//! Error types for ZDBC operations

const std = @import("std");

/// Database operation errors
pub const Error = error{
    /// Invalid URI format
    InvalidUri,
    /// Connection to database failed
    ConnectionFailed,
    /// Database is not connected
    NotConnected,
    /// SQL syntax error
    SqlError,
    /// Query execution failed
    ExecutionFailed,
    /// Invalid parameter binding
    InvalidParameter,
    /// Parameter binding failed
    BindError,
    /// Statement preparation failed
    PrepareFailed,
    /// Type conversion error
    TypeMismatch,
    /// Out of memory
    OutOfMemory,
    /// Column index out of bounds
    ColumnOutOfBounds,
    /// Column not found by name
    ColumnNotFound,
    /// No more rows available
    NoMoreRows,
    /// Statement not prepared
    StatementNotPrepared,
    /// Transaction error
    TransactionError,
    /// Pool exhausted
    PoolExhausted,
    /// Connection timeout
    Timeout,
    /// Driver not implemented
    NotImplemented,
    /// Unsupported backend
    UnsupportedBackend,
    /// Driver not enabled at build time
    DriverNotEnabled,
    /// Result already consumed
    ResultConsumed,
    /// Database is busy
    Busy,
    /// Database locked
    Locked,
    /// Constraint violation
    ConstraintViolation,
    /// Permission denied
    PermissionDenied,
    /// Internal driver error
    InternalError,
};
