#pragma once

#include <optional>
#include <stdexcept>
#include <string>
#include <utility>

namespace cadnext {

enum class ErrorCode {
    None,
    InvalidArgument,
    NotFound,
    KernelUnavailable,
    KernelOperationFailed,
    ShapeInvalid,
    SerializationFailed,
    UnsupportedOperation
};

struct Error {
    ErrorCode code = ErrorCode::None;
    std::string message;
};

template <typename T>
class Result {
public:
    static Result<T> ok(T value) {
        Result<T> result;
        result.value_ = std::move(value);
        return result;
    }

    static Result<T> fail(Error error) {
        Result<T> result;
        result.error_ = std::move(error);
        return result;
    }

    bool isOk() const {
        return value_.has_value();
    }

    const T& value() const {
        if (!value_) {
            throw std::logic_error("Result has no value");
        }
        return *value_;
    }

    const Error& error() const {
        return error_;
    }

private:
    std::optional<T> value_;
    Error error_;
};

} // namespace cadnext
